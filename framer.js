/* Finds the person in the camera picture and frames them the way the sign
   model reads best - and says how to stand when they are not where they
   should be.

   A small pose model (MediaPipe Pose Landmarker lite, in pose-worker.js, on
   the CPU so it never competes with the sign model for the GPU) finds the
   shoulders and the nose about five times a second. From them comes a crop
   in "shoulder widths", measured on the lesson video where recognition was
   best:

       width 2.4, height 2.9, top 1.6 above the shoulder line,
       centred between the shoulders                      (bottom ~ the waist)

   Replayed on that video, this automatic crop recognises as well as the best
   hand-made one (13 right words) - and, unlike a fixed crop, follows a person
   who steps aside or closer.

   The crop is smoothed (time constant ~0.5 s): a crop that jitters is motion
   the sign model would try to read as a gesture. */

const Framer = (() => {
  const K = { w: 2.4, h: 2.9, up: 1.6 };
  const EVERY_MS = 180;                          // pose rate, ~5.5 Hz
  const SMOOTH = 0.35;                           // per sample
  const LOST_MS = 1200;                          // nobody seen this long: say so
  const FORGET_MS = 2500;                        // ...and this long: drop the crop
  const ADVICE_MS = 700;                         // a hint must hold this long to show
  const SMALL = 256;                             // the pose model works at 256 px anyway

  const ADVICE = {
    none: "Встаньте перед камерой",
    close: "Отойдите чуть дальше",
    far: "Подойдите ближе",
    side: "Встаньте по центру",
  };

  let worker = null;
  let busy = false;
  let lastRun = 0;
  let lastSeen = 0;
  let frameW = 0, frameH = 0;                    // size of the frame the pending pass was taken from
  let state = null;                              // smoothed [cx, cy, S] in video pixels
  let candidate = null, candidateSince = 0;
  let small = null, smallCtx = null;

  const info = { crop: null, advice: null, ms: 0, ready: false };

  function load() {
    if (worker) return;
    try {
      worker = new Worker("pose-worker.js");
    } catch (e) {
      console.warn("RSL: no pose worker", e);    // the app falls back to the on-screen crop
      return;
    }
    worker.onmessage = (e) => {
      const d = e.data;
      if (d.ready) { info.ready = true; return; }
      if (d.failed) { console.warn("RSL: pose model unavailable:", d.failed); return; }
      busy = false;
      info.ms = d.ms;
      digest(d.points, performance.now());
    };
    worker.onerror = (e) => { console.warn("RSL: pose worker error", e.message); busy = false; };
    worker.postMessage({ init: new URL(".", location.href).href });
  }

  /* Where the crop should be for these landmarks, before smoothing. */
  function target(p, W, H) {
    const { ls, rs, nose } = p;
    if (Math.min(ls.v, rs.v) < 0.5) return null;
    const sw = Math.abs(ls.x - rs.x) * W;
    const sy = (ls.y + rs.y) / 2 * H;
    const neck = Math.max(0, sy - nose.y * H);
    // Turned sideways, the shoulders look narrow; the neck keeps the scale.
    const S = Math.max(sw, 1.45 * neck);
    if (S < 8) return null;
    const cx = (ls.x + rs.x) / 2 * W;
    return [cx, sy - K.up * S + K.h * S / 2, S];
  }

  function crop(cx, cy, S, W, H) {
    let w = K.w * S, h = K.h * S;
    if (w > W || h > H) {                         // too close: as much as the frame allows
      const f = Math.min(W / w, H / h);
      w *= f; h *= f;
    }
    const x = Math.min(Math.max(cx - w / 2, 0), W - w);
    const y = Math.min(Math.max(cy - h / 2, 0), H - h);
    return { x, y, w, h };
  }

  /* What is wrong with where the person stands, judged on the unclamped crop. */
  function judge(cx, cy, S, W, H) {
    const w = K.w * S, h = K.h * S;
    const top = cy - h / 2;
    if (h > H * 1.08 || w > W * 1.05 || top < -0.08 * H) return "close";
    const left = cx - w / 2, right = cx + w / 2;
    if (left < -0.12 * w || right > W + 0.12 * w) return "side";
    if (h < H * 0.35) return "far";
    return null;
  }

  function settle(next, now) {
    if (next !== candidate) {
      candidate = next;
      candidateSince = now;
    }
    if (now - candidateSince >= ADVICE_MS) info.advice = candidate ? ADVICE[candidate] : null;
  }

  function digest(points, now) {
    const W = frameW, H = frameH;
    const t = points ? target(points, W, H) : null;
    if (t) {
      lastSeen = now;
      state = state ? state.map((v, i) => v + SMOOTH * (t[i] - v)) : t;
      settle(judge(state[0], state[1], state[2], W, H), now);
    } else {
      if (now - lastSeen > FORGET_MS) state = null;
      settle(now - lastSeen > LOST_MS ? "none" : candidate, now);
    }
    info.crop = state ? crop(state[0], state[1], state[2], W, H) : null;
  }

  /* Call on every captured frame; hands one to the pose model every EVERY_MS. */
  function update(video, now) {
    if (!info.ready || busy || now - lastRun < EVERY_MS) return;
    const W = video.videoWidth, H = video.videoHeight;
    if (!W || !H || video.readyState < 2) return;
    lastRun = now;

    // A small copy for the worker: scaling happens on the GPU, and the worker
    // never has to read a full camera frame back.
    const s = SMALL / Math.max(W, H);
    const w = Math.max(1, Math.round(W * s)), h = Math.max(1, Math.round(H * s));
    if (!small) {
      small = document.createElement("canvas");
      smallCtx = small.getContext("2d");
    }
    if (small.width !== w || small.height !== h) { small.width = w; small.height = h; }
    smallCtx.drawImage(video, 0, 0, w, h);

    busy = true;
    frameW = W; frameH = H;
    createImageBitmap(small)
      .then((bitmap) => worker.postMessage({ bitmap, t: now }, [bitmap]))
      .catch(() => { busy = false; });
  }

  function reset() {
    state = null;
    info.crop = null;
    info.advice = null;
    candidate = null;
    lastSeen = performance.now();                // a moment's grace before "nobody here"
  }

  return { load, update, reset, info };
})();
