/* Camera and sign recognition, with no interface of their own.

   The interface (app.js) asks for three things: start, stop, and to be told
   what happens - a recognised word, a message for the person in front of the
   camera, whether anyone is in the frame.

   Two recognisers, one at a time: the server's SignFlow-R while it answers
   (cloud.js), the device's S3D otherwise (recognizer.js). The person is
   found and cropped by framer.js, which also says how to stand. */

const Capture = (() => {
  let video = null;
  let stream = null;
  let wanted = false;                              // the interface wants recognition on
  let capturing = false;
  let captureDelay = 0;
  let captureSince = 0;
  let usingCloud = null;
  let modelState = "idle";                         // idle | loading | ready | failed
  let modelError = null;
  let person = false;
  let listening = false;                           // the model sees a sign taking shape

  let onWord = () => {};
  let onMessage = () => {};
  let onPerson = () => {};
  let onListening = () => {};

  /* --------------------------------------------------------------- messages */

  // One line at a time, the most pressing first.
  const issues = new Map();
  const ORDER = ["camera", "model", "frozen", "pose", "slow"];
  let shown = null;

  function setIssue(key, text) {
    if (text) issues.set(key, text);
    else issues.delete(key);
    const top = ORDER.find((k) => issues.has(k));
    const next = top ? issues.get(top) : null;
    if (next !== shown) {
      shown = next;
      onMessage(next);
    }
  }

  /* ----------------------------------------------------------------- camera */

  /* ?demo=<video file> plays a recording instead of the camera. It is how the
     app is checked against a known clip on a laptop; nothing else uses it. */
  const DEMO = new URLSearchParams(location.search).get("demo");

  async function openCamera() {
    if (stream) return true;
    if (DEMO) {
      video.srcObject = null;
      video.src = DEMO;
      video.loop = true;
      video.muted = true;
      try { await video.play(); } catch (e) { /* needs a tap on some browsers */ }
      video.classList.add("ready");
      stream = { demo: true };
      setIssue("camera", null);
      return true;
    }
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setIssue("camera", "Камера доступна только по HTTPS");
      return false;
    }
    let s;
    try {
      s = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: {
          facingMode: "user",                      // the front camera faces the signer
          width: { ideal: 1280 },
          height: { ideal: 720 },
          frameRate: { ideal: 30 },
        },
      });
    } catch (err) {
      setIssue("camera", err && err.name === "NotAllowedError"
        ? "Нет доступа к камере" : "Камера недоступна");
      return false;
    }
    if (!wanted) {                                 // left the screen while the prompt was up
      s.getTracks().forEach((t) => t.stop());
      return false;
    }
    stream = s;
    video.srcObject = stream;
    try { await video.play(); } catch (e) { /* autoplay is muted */ }
    video.classList.add("ready");
    stream.getVideoTracks()[0].addEventListener("ended", () => {
      if (!stream) return;
      stream = null;
      video.classList.remove("ready");
      halt();
      setIssue("camera", "Камера отключилась");
    });
    setIssue("camera", null);
    return true;
  }

  /* Releases the camera, so its indicator goes out when the screen is left. */
  function closeCamera() {
    if (stream && stream.getTracks) {
      const s = stream;
      stream = null;
      s.getTracks().forEach((t) => t.stop());
    } else if (stream) {
      stream = null;
      video.pause();
    }
    video.classList.remove("ready");
    video.srcObject = null;
  }

  /* ------------------------------------------------------------------ model */

  async function loadModel() {
    if (modelState === "loading" || modelState === "ready") return;
    modelState = "loading";
    try {
      await Recognizer.load((got, total) => {
        const pct = total ? Math.round(got / total * 100) : Math.round(got / 19124257 * 100);
        // With the server answering, the device's model is only a reserve:
        // it loads quietly and nobody has to wait for it.
        setIssue("model", Cloud.online || !wanted ? null : `Загрузка распознавания… ${Math.min(99, pct)}%`);
      });
      modelState = "ready";
      setIssue("model", null);
      if (wanted) beginCapture();                  // asked for while it was still loading
    } catch (err) {
      modelState = "failed";
      modelError = err && err.message === "no-webgpu"
        ? "Устройство не поддерживает распознавание"
        : "Не удалось загрузить распознавание";
      console.error("RSL: model failed", err);
      setIssue("model", Cloud.online || !wanted ? null : modelError);
    }
  }

  function hear(top) {
    // A sign is taking shape when the model's best guess is not "nothing".
    const t = top && top[0];
    const now = Boolean(capturing && t && t.p >= 0.2 && t.label !== "no" && t.label !== "№0");
    if (now !== listening) {
      listening = now;
      onListening(now);
    }
  }

  Recognizer.onWord = (label) => {
    if (capturing && !Cloud.online) onWord(label);
  };

  Cloud.onWord = (label) => {
    if (capturing) onWord(label);
  };

  Cloud.onStats = (stats) => {
    if (stats.online) {
      setIssue("model", null);
      for (const k of ["frozen", "slow"]) setIssue(k, null);   // those are the device model's
      if (wanted && !capturing) beginCapture();    // asked for before anything was ready
      hear(stats.top);
    } else if (modelState === "failed" && wanted) {
      setIssue("model", modelError);               // no server and no model in the device
    }
  };

  Recognizer.onStats = (stats) => {
    setIssue("frozen", capturing && stats.frozen ? "Камера закрыта: картинка не меняется" : null);
    // The model reads 32 frames as about one second. Far fewer frames per second
    // stretch that window, the sign arrives in slow motion and accuracy falls apart.
    const slow = capturing && captureSince && Date.now() - captureSince > 3000 &&
                 stats.fps > 0 && stats.fps < 18;
    setIssue("slow", slow ? `Мало кадров с камеры (${stats.fps.toFixed(0)}/с)` : null);
    if (!Cloud.online) hear(stats.top);
  };

  /* ---------------------------------------------------------------- capture */

  /* Browsers throttle main-thread timers to ~1 Hz in a hidden tab; timers in a
     worker are not throttled, so the capture clock ticks from one. */
  let ticker = null;
  let fallbackTimer = 0;

  function ensureTicker() {
    if (ticker === null) {
      try {
        const src = "let id=null;onmessage=(e)=>{clearInterval(id);id=null;" +
                    "if(!e.data.stop){id=setInterval(()=>postMessage(0),e.data.interval);}};";
        ticker = new Worker(URL.createObjectURL(new Blob([src], { type: "text/javascript" })));
        ticker.onmessage = captureFrame;
      } catch (e) {
        ticker = false;
      }
    }
    return ticker;
  }

  function startLoop() {
    if (ensureTicker()) {
      ticker.postMessage({ interval: 33 });
      return;
    }
    clearTimeout(fallbackTimer);
    const tick = () => {
      if (!capturing) return;
      captureFrame();
      fallbackTimer = setTimeout(tick, 33);
    };
    tick();
  }

  function stopLoop() {
    if (ticker) ticker.postMessage({ stop: true });
    clearTimeout(fallbackTimer);
  }

  /* While nobody has been found, the model gets what the person sees: the part
     of the camera picture inside the camera block. The video fills that block
     with object-fit: cover, so much of the frame never reaches the screen. */
  function visibleCrop() {
    const vw = video.videoWidth, vh = video.videoHeight;
    const W = video.clientWidth, H = video.clientHeight;
    if (!vw || !vh || !W || !H) return null;
    const s = Math.max(W / vw, H / vh);
    const ox = (W - vw * s) / 2, oy = (H - vh * s) / 2;
    return { x: -ox / s, y: -oy / s, w: W / s, h: H / s };
  }

  function captureFrame() {
    if (!capturing || !stream) return;
    Framer.update(video, performance.now());
    const crop = Framer.info.crop || visibleCrop();
    const cloud = Cloud.online;
    if (cloud !== usingCloud) {                    // the server came or went: start clean
      usingCloud = cloud;
      if (cloud) Cloud.start();
      else if (modelState === "ready") Recognizer.start();
    }
    if (cloud) Cloud.pushFrame(video, crop);
    else if (modelState === "ready") Recognizer.pushFrame(video, crop);
    setIssue("pose", Framer.info.advice);
    const seen = Boolean(Framer.info.crop);
    if (seen !== person) {
      person = seen;
      onPerson(seen);
    }
  }

  function beginCapture() {
    if (capturing || !(modelState === "ready" || Cloud.online)) return;
    capturing = true;
    usingCloud = null;
    Framer.reset();
    // Frames and inference are the heaviest work there is. Let the screen's
    // transition play out on a quiet main thread first; the model needs a
    // second of video before it can say anything anyway.
    clearTimeout(captureDelay);
    captureDelay = setTimeout(() => {
      if (!capturing) return;
      captureSince = Date.now();
      startLoop();
    }, 450);
  }

  function halt() {
    capturing = false;                             // not one more frame is read
    clearTimeout(captureDelay);
    stopLoop();
    Recognizer.stop();
    Cloud.stop();
    for (const k of ["pose", "frozen", "slow", "model"]) setIssue(k, null);
    if (person) { person = false; onPerson(false); }
    if (listening) { listening = false; onListening(false); }
  }

  /* -------------------------------------------------------------- interface */

  /* Camera on and recognition running. */
  async function start() {
    wanted = true;
    keepAwake();
    if (modelState === "failed" && !Cloud.online) setIssue("model", modelError);
    if (!(await openCamera())) return;
    if (!wanted) return;
    if (modelState === "ready" || Cloud.online) beginCapture();
    else loadModel();                              // capture begins when it lands
  }

  /* Recognition off, the picture stays (the «Жест» button pressed again). */
  function pause() {
    wanted = false;
    halt();
  }

  /* Recognition off and the camera released. */
  function stop() {
    wanted = false;
    halt();
    closeCamera();
    setIssue("camera", null);
  }

  let wakeLock = null;
  async function keepAwake() {
    try {
      if (!wakeLock && "wakeLock" in navigator) {
        wakeLock = await navigator.wakeLock.request("screen");
        wakeLock.addEventListener("release", () => { wakeLock = null; });
      }
    } catch (e) { /* unsupported or refused */ }
  }
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && wanted) keepAwake();
  });

  /* Call once, with the <video> the picture goes to. Downloading and compiling
     the models takes a while on a first run, so it starts right away. */
  function init(videoEl) {
    video = videoEl;
    ensureTicker();
    loadModel();
    Framer.load();
    Cloud.init();
  }

  return {
    init, start, pause, stop,
    get capturing() { return capturing; },
    get stats() { return Cloud.online ? Cloud.stats : Recognizer.stats; },
    get online() { return Cloud.online; },
    set onWord(fn) { onWord = fn; },
    set onMessage(fn) { onMessage = fn; },
    set onPerson(fn) { onPerson = fn; },
    set onListening(fn) { onListening = fn; },
  };
})();
