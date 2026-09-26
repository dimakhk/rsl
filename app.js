/* Sign recognition in two states, laid out after the Figma mockup
   (800x1280 design units, portrait).

     A  waiting  the camera card is defocused, «НАЧАТЬ» sits under it
     B  active   the card comes into focus, recognised signs take the
                 button's place - two lines at most

   Both states are the two ends of one spring, `scene` (0 = A, 1 = B).
   Everything on screen is a function of that single value, so an
   interruption in either direction is continuous by construction: retarget
   the spring and the whole picture turns around from wherever it is.

   Recognition happens in this device (recognizer.js). There is no server:
   once the app has been opened with a connection, it works without one. */

const $ = (id) => document.getElementById(id);

const cameraEl = $("camera");
const video = $("video");
const startBtn = $("start");
const captionsEl = $("captions");
const viewportEl = $("viewport");
const wordsEl = $("words");
const placeholderEl = $("placeholder");
const statusEl = $("status");
const creditEl = $("credit");

const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
const clamp01 = (v) => Math.min(1, Math.max(0, v));

/* ================================================================ scene */

const BLUR = 20;                                  // defocus in state A, design units
const scene = new Spring(0, { damping: 1, response: 0.4 });   // 0 = A, 1 = B
let wantB = false;                                // where the scene is headed
let unit = 1;                                     // CSS px per design unit
let overscan = 1.1;                               // zoom that keeps the blur's soft rim hidden

function renderScene(raw) {
  const p = clamp01(raw);
  const defocus = 1 - p;
  const still = reduceMotion.matches;

  // Lens: blur and a touch of zoom travel together inside the card, so it
  // reads as focus being pulled rather than a filter being switched. At rest
  // in B the filter is removed altogether, which also takes its GPU cost away.
  const blur = BLUR * unit * defocus;
  video.style.filter = blur > 0.05 ? `blur(${blur.toFixed(2)}px)` : "none";
  const s = still ? overscan : 1 + (overscan - 1) * defocus;
  video.style.transform = `scale(${(-s).toFixed(4)}, ${s.toFixed(4)})`;   // mirrored selfie

  // The button and the text share one spot. They cross through empty rather
  // than overlapping: the button is gone by p = 0.5, the text starts there.
  const bo = clamp01(1 - p / 0.5);
  startBtn.style.opacity = bo.toFixed(3);
  startBtn.style.transform = still ? "none" : `scale(${(1 - 0.08 * p).toFixed(4)})`;
  startBtn.style.visibility = bo > 0.001 ? "visible" : "hidden";

  const co = clamp01((p - 0.5) / 0.5);
  captionsEl.style.opacity = co.toFixed(3);
  captionsEl.style.transform = still ? "none" : `translateY(${(10 * unit * defocus).toFixed(2)}px)`;
  captionsEl.style.visibility = co > 0.001 ? "visible" : "hidden";

  creditEl.style.opacity = (0.45 * clamp01(1 - p / 0.3)).toFixed(3);
}

function sceneTask(dt) {
  scene.step(dt);
  renderScene(scene.value);
  if (scene.settled && !wantB) Captions.clear(false);   // at rest in A: drop the old text
  return !scene.settled;
}

function goTo(b) {
  wantB = b;
  const target = b ? 1 : 0;
  scene.to(target);
  // A tap is an impulse, so the very first frame already moves. Proportional
  // to the distance left and well below the critical value 2π/response, so a
  // critically damped spring still cannot overshoot.
  scene.velocity += (b ? 1 : -1) * 5 * Math.abs(target - scene.value);
  startBtn.style.pointerEvents = b ? "none" : "auto";
  Animator.run(sceneTask);
}

/* ============================================================= captions */

const Captions = (() => {
  const words = [];                                // { el, x, y, a, out, leaving }
  const POS = { damping: 1, response: 0.4, precision: 0.1 };
  const APPEAR = { damping: 1, response: 0.4, precision: 0.002 };
  const LINES = 2;
  let lineHeight = 73;

  function measure() {
    const cs = getComputedStyle(captionsEl);
    lineHeight = parseFloat(cs.lineHeight) || 73;
    // Words are separate flex items; the gap between them is the face's own space.
    const c = document.createElement("canvas").getContext("2d");
    c.font = `${cs.fontSize} ${cs.fontFamily}`;
    wordsEl.style.columnGap = c.measureText(" ").width.toFixed(2) + "px";
  }

  function apply(w) {
    const a = clamp01(w.a.value);
    const s = reduceMotion.matches ? 1 : 0.94 + 0.06 * a;
    w.el.style.opacity = a.toFixed(3);
    w.el.style.transform =
      `translate3d(${w.x.value.toFixed(2)}px, ${w.y.value.toFixed(2)}px, 0) scale(${s.toFixed(4)})`;
  }

  /* Only the newest LINES rows stay. One row sits centred where the button was;
     from two rows on the block is bottom-anchored, and a row pushed above them
     rises and dissolves on its own spring. */
  function updateRows() {
    const live = words.filter((w) => !w.leaving);
    const tops = [...new Set(live.map((w) => w.el.offsetTop))].sort((a, b) => a - b);
    for (const w of live) {
      const out = tops.indexOf(w.el.offsetTop) < tops.length - LINES;
      if (out !== w.out) {
        w.out = out;
        w.a.to(out ? 0 : 1);
      }
    }
    // Moves rows vertically, never changes which words share a row.
    viewportEl.classList.toggle("single", tops.length <= 1);
  }

  /* FLIP with springs: note where every word is on screen, change the DOM,
     then offset each word back to where it was and let its spring pull it to
     its new place. Offsets add onto a word already in motion, so a layout
     change mid-flight never makes anything jump. */
  function mutate(change) {
    const list = words.slice();
    const before = list.map((w) => w.el.getBoundingClientRect());
    change();
    updateRows();
    if (reduceMotion.matches) return Animator.run(task);
    list.forEach((w, i) => {
      if (!w.el.isConnected) return;
      const after = w.el.getBoundingClientRect();
      const dx = before[i].left - after.left;
      const dy = before[i].bottom - after.bottom;   // origin is bottom-centre: scale can't skew it
      if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) {
        w.x.set(w.x.value + dx).to(0);
        w.y.set(w.y.value + dy).to(0);
        apply(w);                                  // same frame: nothing is seen to jump
      }
    });
    Animator.run(task);
  }

  function add(label) {
    placeholderEl.classList.add("gone");
    mutate(() => {
      const el = document.createElement("span");
      el.className = "w";
      el.textContent = label;
      wordsEl.appendChild(el);
      const rise = reduceMotion.matches ? 0 : lineHeight * 0.35;
      const w = {
        el,
        x: new Spring(0, POS),
        y: new Spring(rise, POS).to(0),
        a: new Spring(0, APPEAR).to(1),
        out: false,
        leaving: false,
      };
      words.push(w);
      apply(w);
    });
  }

  function removeWhere(pred) {
    mutate(() => {
      for (let i = words.length - 1; i >= 0; i--) {
        if (pred(words[i])) {
          words[i].el.remove();
          words.splice(i, 1);
        }
      }
    });
  }

  /* Dissolved rows are dead weight. They go only as whole rows, all at once:
     removing part of a row would re-wrap everything under it. The block is
     bottom-anchored by then, so dropping top rows moves nothing visible. */
  function pruneScrolledOut() {
    const out = words.filter((w) => w.out);
    if (out.length && out.every((w) => w.a.settled && w.a.value === 0)) {
      const doomed = new Set(out);
      removeWhere((w) => doomed.has(w));
    }
  }

  function task(dt) {
    let moving = false;
    for (const w of words) {
      w.x.step(dt);
      w.y.step(dt);
      w.a.step(dt);
      apply(w);
      if (!(w.x.settled && w.y.settled && w.a.settled)) moving = true;
    }
    if (words.some((w) => w.leaving && w.a.settled)) {
      removeWhere((w) => w.leaving && w.a.settled);
      moving = true;
    }
    if (!moving) pruneScrolledOut();
    return moving;
  }

  function clear(animated) {
    if (!animated) {
      words.length = 0;
      wordsEl.textContent = "";
      viewportEl.classList.add("single");
      placeholderEl.classList.remove("gone");
      return;
    }
    for (const w of words) {
      w.leaving = true;
      w.a.to(0);
    }
    Animator.run(task);
  }

  return { add, clear, measure };
})();

/* =============================================================== status */

const issues = new Map();
const ISSUE_ORDER = ["camera", "model", "frozen", "slow"];

function setIssue(key, text) {
  if (text) issues.set(key, text);
  else issues.delete(key);
  const top = ISSUE_ORDER.find((k) => issues.has(k));
  if (top) statusEl.textContent = issues.get(top);
  statusEl.classList.toggle("on", Boolean(top));
}

/* =============================================================== camera */

let stream = null;

/* ?demo=<video file> plays a recording instead of the camera. It is how this
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
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        facingMode: "user",                        // the front camera faces the signer
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
  video.srcObject = stream;
  try { await video.play(); } catch (e) { /* autoplay is muted; retried on start */ }
  video.classList.add("ready");
  stream.getVideoTracks()[0].addEventListener("ended", () => {
    stream = null;
    video.classList.remove("ready");
    stop();
    setIssue("camera", "Камера отключилась");
  });
  setIssue("camera", null);
  return true;
}

/* ================================================================ model */

let modelState = "idle";                           // idle | loading | ready | failed

async function loadModel() {
  if (modelState === "loading" || modelState === "ready") return;
  modelState = "loading";
  try {
    await Recognizer.load((got, total) => {
      const pct = total ? Math.round(got / total * 100) : Math.round(got / 19124257 * 100);
      setIssue("model", `Загрузка распознавания… ${Math.min(99, pct)}%`);
    });
    modelState = "ready";
    setIssue("model", null);
    if (wantB) beginCapture();                     // pressed while it was still loading
  } catch (err) {
    modelState = "failed";
    console.error("RSL: model failed", err);
    setIssue("model", err && err.message === "no-webgpu"
      ? "Устройство не поддерживает распознавание (нужен WebGPU)"
      : "Не удалось загрузить распознавание");
  }
}

Recognizer.onWord = (label) => {
  if (capturing) Captions.add(label);
};

Recognizer.onStats = (stats) => {
  setIssue("frozen", capturing && stats.frozen
    ? "Нет изображения: картинка не меняется — камера закрыта" : null);
  // The model reads 32 frames as about one second. Far fewer frames per second
  // stretch that window, the sign arrives in slow motion and accuracy falls apart.
  const slow = capturing && captureSince && Date.now() - captureSince > 3000 &&
               stats.fps > 0 && stats.fps < 18;
  setIssue("slow", slow ? `Мало кадров с камеры (${stats.fps.toFixed(0)}/с)` : null);
};

/* ============================================================== capture */

/* Browsers throttle main-thread timers to ~1 Hz in a hidden tab; timers in a
   worker are not throttled, so the capture clock ticks from one. */
let ticker = null;
let fallbackTimer = null;
let capturing = false;
let captureDelay = 0;
let captureSince = 0;

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

function startCaptureLoop() {
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

function stopCaptureLoop() {
  if (ticker) ticker.postMessage({ stop: true });
  clearTimeout(fallbackTimer);
}

function captureFrame() {
  if (!capturing || !stream) return;
  Recognizer.pushFrame(video);
}

function beginCapture() {
  if (capturing || modelState !== "ready") return;
  capturing = true;
  Recognizer.start();
  // Frames and inference are the heaviest work there is. Let the transition
  // play out on a quiet main thread first; the model needs a second of video
  // before it can say anything anyway.
  clearTimeout(captureDelay);
  captureDelay = setTimeout(() => {
    if (!capturing) return;
    captureSince = Date.now();
    startCaptureLoop();
  }, 450);
}

/* ======================================================= start and stop */

function buzz() {
  // Fires in the same handler as the visual change, so sight and touch agree.
  try { if (navigator.vibrate) navigator.vibrate(8); } catch (e) { /* unsupported */ }
}

async function start() {
  if (wantB) return;
  goTo(true);
  buzz();
  resetTaps();
  Captions.clear(captionsEl.style.visibility === "visible");
  placeholderEl.classList.remove("gone");
  keepAwake();
  if (!stream) await openCamera();
  if (modelState === "ready") beginCapture();
  else loadModel();                                // starts capture when it lands
}

function stop() {
  if (!wantB) return;
  capturing = false;                               // not one more frame is read
  clearTimeout(captureDelay);
  stopCaptureLoop();
  Recognizer.stop();
  goTo(false);
  buzz();
  resetTaps();
}

/* ============================================================== gestures */

// Commit on touch-down: the press itself is the start, nothing waits for release.
startBtn.addEventListener("pointerdown", (e) => {
  if (e.button !== 0) return;
  e.preventDefault();
  start();
});
startBtn.addEventListener("keydown", (e) => {
  if (e.key === "Enter" || e.key === " ") {
    e.preventDefault();
    start();
  }
});
addEventListener("keydown", (e) => {
  if (e.key === "Escape") stop();
});

/* A clean double tap anywhere stops recognition. "Clean": each tap short and
   still (under 10 px of drift), the second landing within 300 ms and 32 px of
   the first, one finger only. It fires on the second touch-down. */
const TAP_TIME = 250;
const TAP_SLOP = 10;
const DOUBLE_GAP = 300;
const DOUBLE_SLOP = 32;
const activePointers = new Set();
let press = null;
let lastTap = null;

function resetTaps() {
  press = null;
  lastTap = null;
}

addEventListener("pointerdown", (e) => {
  if (e.isPrimary) activePointers.clear();          // a new gesture begins
  activePointers.add(e.pointerId);
  if (!wantB || (e.target.closest && e.target.closest("#start"))) return;
  if (activePointers.size > 1) return resetTaps();  // a pinch is not a tap

  if (lastTap && e.timeStamp - lastTap.t <= DOUBLE_GAP &&
      Math.hypot(e.clientX - lastTap.x, e.clientY - lastTap.y) <= DOUBLE_SLOP) {
    stop();
    return;
  }
  press = { id: e.pointerId, x: e.clientX, y: e.clientY, t: e.timeStamp };
});

addEventListener("pointermove", (e) => {
  if (press && e.pointerId === press.id &&
      Math.hypot(e.clientX - press.x, e.clientY - press.y) > TAP_SLOP) {
    press = null;
  }
});

function pointerEnd(e) {
  activePointers.delete(e.pointerId);
  if (press && e.pointerId === press.id && e.type === "pointerup" &&
      e.timeStamp - press.t <= TAP_TIME) {
    lastTap = { x: e.clientX, y: e.clientY, t: e.timeStamp };
  }
  if (press && e.pointerId === press.id) press = null;
}
addEventListener("pointerup", pointerEnd);
addEventListener("pointercancel", pointerEnd);
addEventListener("contextmenu", (e) => e.preventDefault());   // no long-press menus on a kiosk

/* ============================================================== plumbing */

let wakeLock = null;
async function keepAwake() {
  try {
    if (!wakeLock && "wakeLock" in navigator) {
      wakeLock = await navigator.wakeLock.request("screen");
      wakeLock.addEventListener("release", () => { wakeLock = null; });
    }
  } catch (e) { /* unsupported or refused; the stand's auto-lock covers it */ }
}
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) keepAwake();
});

function layout() {
  unit = cameraEl.offsetWidth / 652;               // the card is 652 mockup px wide
  // Blur spreads roughly two standard deviations past the edge; zoom the video
  // enough inside the card that its soft, darkened rim stays out of sight.
  const inner = Math.max(1, Math.min(cameraEl.clientWidth, cameraEl.clientHeight));
  overscan = 1 + (4 * BLUR * unit) / inner;
  Captions.measure();
  renderScene(scene.value);
}

reduceMotion.addEventListener("change", () => renderScene(scene.value));
addEventListener("resize", layout);
if (document.fonts && document.fonts.ready) document.fonts.ready.then(layout);

/* The offline cache holds a whole version of the app, which is exactly what
   makes it unusable while that version is being written: every edit would be
   served from the previous copy. It is switched off on a development machine. */
const LOCAL = ["localhost", "127.0.0.1", "::1"].includes(location.hostname);
if ("serviceWorker" in navigator && !LOCAL) {
  addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));
}

layout();
openCamera();
keepAwake();
ensureTicker();
// Downloading and compiling the model takes a while on a first run, so it
// starts now rather than when someone is standing in front of the camera.
loadModel();
