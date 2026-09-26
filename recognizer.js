/* Sign recognition that runs inside the device.

   The model is easy_sign's S3D, rebuilt out of 2D operators (see
   ../tools/to_2d.py) because browsers run those on the GPU and 3D ones not at
   all. It reads 32 frames at a time - about one second of video - and names the
   sign in them.

   The pace sets itself. A fast tablet finishes a window in ~0.18 s and can
   start a new one every 8 frames; a phone takes ~0.6 s and gets one every 20.
   Since a rarer window means fewer chances to see the same sign twice, the
   acceptance rule loosens in step (see RULE).                                */

const Recognizer = (() => {
  const SIDE = 224;
  const PLANE = 3 * SIDE * SIDE;                 // one frame, planar RGB
  const WINDOW = 32;                             // frames the model reads at once
  const FRAME_MS = 1000 / 30;
  const BLANK = "no";                            // the model's "no sign here" class

  /* Measured on the lesson video: with a window every 8-12 frames a sign is
     seen several times, so demanding two windows in a row cuts the wrong words
     without losing right ones. Rarer than that, most signs get one window
     only, and the same demand would drop half the vocabulary. */
  const RULE = {
    threshold: 0.7,      // a window counts as confident from here
    instant: 0.9,        // this sure on its own: accept without a second window
    dense: 12,           // up to this stride, wait for two windows in a row
  };

  let session = null;
  let labels = [];
  const frames = [];                             // ring of WINDOW planar frames
  for (let i = 0; i < WINDOW; i++) frames.push(new Float32Array(PLANE));
  const input = new Float32Array(WINDOW * PLANE);

  let head = 0;                                  // next slot to write
  let filled = 0;                                // frames in the ring, up to WINDOW
  let sinceInfer = 0;
  let busy = false;
  let running = false;

  let canvas = null, ctx = null;
  const motion = [];                             // recent frame-to-frame change

  let streakLabel = null, streak = 0;
  let lastAccepted = null;

  const recent = [];                             // recent inference times, ms
  const stats = { inferMs: 0, stride: 8, fps: 0, frozen: false, ready: false };
  const recvTimes = [];

  let onWord = () => {};
  let onStats = () => {};

  /* ------------------------------------------------------------- loading */

  async function fetchWithProgress(url, onProgress) {
    const res = await fetch(url);
    if (!res.ok) throw new Error(url + ": HTTP " + res.status);
    const total = Number(res.headers.get("content-length")) || 0;
    const reader = res.body.getReader();
    const chunks = [];
    let got = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      got += value.length;
      onProgress(got, total);
    }
    const out = new Uint8Array(got);
    let at = 0;
    for (const c of chunks) { out.set(c, at); at += c.length; }
    return out;
  }

  async function load(onProgress) {
    if (session) return;
    if (!navigator.gpu) throw new Error("no-webgpu");
    labels = await (await fetch("model/labels.json")).json();
    // The model is the download people wait for; the runtime is fetched by the
    // browser's own cache alongside it and is quick on every later start.
    const bytes = await fetchWithProgress("model/s3d.onnx", onProgress);
    // A bare path is treated as a module specifier, so it has to be absolute.
    ort.env.wasm.wasmPaths = new URL("vendor/", location.href).href;
    ort.env.wasm.numThreads = 1;                 // the GPU does the work
    session = await ort.InferenceSession.create(bytes, { executionProviders: ["webgpu"] });
    // The first run compiles the shaders; do it now, not under the user's nose.
    await session.run({ frames: new ort.Tensor("float32", input, [WINDOW, 3, SIDE, SIDE]) });
    stats.ready = true;
    onStats(stats);
  }

  /* -------------------------------------------------------------- frames */

  /* The whole picture is squashed into a square, which is how S3D was trained
     (the reference app does the same) - not cropped, not letterboxed.

     Turning a video frame into numbers means reading its pixels back from the
     GPU. Done on this thread, that read waits behind the model's own GPU work
     and the whole page stalls with it. So it happens in a worker: this thread
     only hands the frame over (createImageBitmap does not block) and files
     the numbers that come back. The same code runs here as a fallback on
     browsers without a 2D canvas in workers. */
  const CONVERT = `
    function convert(px, f, SIDE) {
      const AREA = SIDE * SIDE;
      for (let i = 0, p = 0; i < AREA; i++, p += 4) {
        f[i] = px[p] / 255;
        f[AREA + i] = px[p + 1] / 255;
        f[2 * AREA + i] = px[p + 2] / 255;
      }
      // How much the picture changed: red channel on a 28x28 grid.
      const small = new Int16Array(784);
      for (let y = 0, i = 0; y < SIDE; y += 8)
        for (let x = 0; x < SIDE; x += 8, i++) small[i] = px[(y * SIDE + x) * 4];
      let motion = -1;
      if (convert.prev) {
        let s = 0;
        for (let i = 0; i < 784; i++) s += Math.abs(small[i] - convert.prev[i]);
        motion = s / 784;
      }
      convert.prev = small;
      return motion;
    }`;

  const GRABBER = CONVERT + `
    const SIDE = ${SIDE};
    let ctx = null;
    const pool = [];
    onmessage = (e) => {
      const d = e.data;
      if (d.give) { pool.push(d.give); return; }
      if (d.reset) { convert.prev = null; return; }
      if (!ctx) ctx = new OffscreenCanvas(SIDE, SIDE).getContext("2d", { willReadFrequently: true });
      ctx.drawImage(d.bitmap, 0, 0, SIDE, SIDE);
      d.bitmap.close();
      const px = ctx.getImageData(0, 0, SIDE, SIDE).data;
      const f = new Float32Array(pool.pop() || new ArrayBuffer(${PLANE * 4}));
      const motion = convert(px, f, SIDE);
      postMessage({ buf: f.buffer, motion }, [f.buffer]);
    };`;

  let grabber = null;                            // Worker, or false: convert here
  // Frames on their way through the worker. More than one may be: the read
  // back can wait behind the model's GPU work, and waiting for each frame
  // before asking for the next would drop frames exactly while it runs.
  let inFlight = 0;
  const MAX_IN_FLIGHT = 3;
  const local = new Function(CONVERT + "; return convert;")();

  function ensureGrabber() {
    if (grabber !== null) return grabber;
    try {
      if (typeof OffscreenCanvas === "undefined" || typeof createImageBitmap !== "function") {
        throw new Error("no OffscreenCanvas");
      }
      grabber = new Worker(URL.createObjectURL(new Blob([GRABBER], { type: "text/javascript" })));
      grabber.onmessage = (e) => {
        inFlight = Math.max(0, inFlight - 1);
        const f = new Float32Array(e.data.buf);
        if (running) file(f, e.data.motion);
        else grabber.postMessage({ give: f.buffer }, [f.buffer]);
      };
      grabber.onerror = () => { grabber = false; inFlight = 0; };
    } catch (e) {
      grabber = false;
    }
    console.info("RSL: frames converted " + (grabber ? "in a worker" : "on the main thread"));
    return grabber;
  }

  function pushFrame(video) {
    if (!running || !session) return;
    if (video.readyState < 2 || !video.videoWidth) return;
    if (ensureGrabber()) {
      if (inFlight >= MAX_IN_FLIGHT) return;     // behind: drop rather than pile up
      inFlight++;
      createImageBitmap(video)
        .then((bitmap) => grabber.postMessage({ bitmap }, [bitmap]))
        .catch(() => { inFlight = Math.max(0, inFlight - 1); });
      return;
    }
    const c = ensureCanvas();
    c.drawImage(video, 0, 0, SIDE, SIDE);
    const f = new Float32Array(PLANE);
    file(f, local(c.getImageData(0, 0, SIDE, SIDE).data, f, SIDE));
  }

  function ensureCanvas() {
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.width = canvas.height = SIDE;
      ctx = canvas.getContext("2d", { willReadFrequently: true });
    }
    return ctx;
  }

  /* Puts a converted frame into the ring. The frame it displaces goes back to
     the worker to be filled again, so steady running allocates nothing. */
  function file(f, change) {
    const old = frames[head];
    frames[head] = f;
    if (old && grabber) grabber.postMessage({ give: old.buffer }, [old.buffer]);
    head = (head + 1) % WINDOW;
    if (filled < WINDOW) filled++;
    sinceInfer++;

    const now = performance.now();
    recvTimes.push(now);
    while (recvTimes.length > 60) recvTimes.shift();
    if (recvTimes.length > 1) {
      stats.fps = (recvTimes.length - 1) * 1000 / (now - recvTimes[0]);
    }
    // A covered lens or a paused video looks to the model like "no sign" for
    // ever, which on screen reads as the app being broken. Spot it instead.
    if (change >= 0) {
      motion.push(change);
      while (motion.length > 60) motion.shift();
      stats.frozen = motion.length === 60 &&
        motion.reduce((a, b) => a + b, 0) / motion.length < 0.3;
    }
    maybeInfer();
  }

  /* ----------------------------------------------------------- inference */

  function softmaxTop(logits) {
    let max = -Infinity, best = 0;
    for (let i = 0; i < logits.length; i++) if (logits[i] > max) { max = logits[i]; best = i; }
    let sum = 0;
    for (let i = 0; i < logits.length; i++) sum += Math.exp(logits[i] - max);
    return { index: best, confidence: 1 / sum };   // exp(max - max) = 1
  }

  function pace(ms) {
    recent.push(ms);
    while (recent.length > 5) recent.shift();
    const sorted = recent.slice().sort((a, b) => a - b);
    const median = sorted[sorted.length >> 1];
    stats.inferMs = median;
    // Leave a little room: a window that starts before the last one is done
    // only queues up work and adds delay.
    stats.stride = Math.min(32, Math.max(8, Math.ceil(median * 1.15 / FRAME_MS)));
  }

  async function maybeInfer() {
    if (busy || filled < WINDOW || sinceInfer < stats.stride) return;
    busy = true;
    sinceInfer = 0;
    for (let i = 0; i < WINDOW; i++) input.set(frames[(head + i) % WINDOW], i * PLANE);
    const t0 = performance.now();
    let out;
    try {
      out = await session.run({ frames: new ort.Tensor("float32", input, [WINDOW, 3, SIDE, SIDE]) });
    } catch (e) {
      busy = false;
      console.error("RSL: inference failed", e);
      return;
    }
    pace(performance.now() - t0);
    busy = false;
    if (!running) return;
    judge(softmaxTop(out.logits.data));
    onStats(stats);
  }

  /* --------------------------------------------------------------- rule */

  function judge(best) {
    const label = labels[best.index];
    const need = stats.stride <= RULE.dense ? 2 : 1;
    const confident = best.confidence >= RULE.threshold && label !== BLANK;

    if (confident && label === streakLabel) streak++;
    else if (confident) { streakLabel = label; streak = 1; }
    else { streakLabel = null; streak = 0; }

    const accept = confident &&
      (streak >= need || best.confidence >= RULE.instant);
    if (!accept) return;

    if (label !== lastAccepted) {
      lastAccepted = label;
      onWord(label, best.confidence);
    }
    // Start the next window from scratch, as the reference app does, so the
    // tail of one sign cannot be read as another.
    filled = 0;
    sinceInfer = 0;
    streakLabel = null;
    streak = 0;
  }

  /* ------------------------------------------------------------ control */

  function start() {
    running = true;
    filled = 0;
    sinceInfer = 0;
    head = 0;
    streakLabel = null;
    streak = 0;
    lastAccepted = null;
    local.prev = null;
    if (ensureGrabber()) grabber.postMessage({ reset: true });
    motion.length = 0;
    recvTimes.length = 0;
    stats.frozen = false;
  }

  function stop() {
    running = false;
  }

  /* Times the model alone, n windows back to back (for the console). */
  async function bench(n = 3) {
    const t = performance.now();
    for (let i = 0; i < n; i++) {
      await session.run({ frames: new ort.Tensor("float32", input, [WINDOW, 3, SIDE, SIDE]) });
    }
    return Math.round((performance.now() - t) / n);
  }

  return {
    load, start, stop, pushFrame, stats, bench,
    get ready() { return Boolean(session); },
    set onWord(fn) { onWord = fn; },
    set onStats(fn) { onStats = fn; },
  };
})();
