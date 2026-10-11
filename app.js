/* The chat interface (Figma mockup 393x852).

   Screens: splash -> start (empty chat) -> gestures | voice | keyboard,
   plus the history screen that slides over them.

   What is real: the camera, sign recognition and the hints about where to
   stand (capture.js). What is only drawn for now, and marked TODO below:
   speech recognition, speaking the text aloud, saving what is typed, and the
   chat history.

   Motion: every transition is a spring (spring.js) that writes transform and
   opacity - directly, or through a custom property the stylesheet reads.
   With "reduce motion" on, the same values are reached by a 150 ms fade. */

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const reduce = matchMedia("(prefers-reduced-motion: reduce)");
const clamp01 = (v) => Math.min(1, Math.max(0, v));
const lerp = (a, b, t) => a + (b - a) * t;

if (params.has("sim")) document.documentElement.classList.add("sim");

const phone = $("phone");
const chat = $("chat");
const camera = $("camera");
const camGlow = $("camGlow");
const video = $("video");
const plaque = $("plaque");
const plaqueText = $("plaqueText");
const feed = $("feed");
const feedInner = $("feedInner");
const intro = $("intro");
const wave = $("wave");
const dock = $("dock");
const kbar = $("kbar");
const kbarInput = $("kbarInput");
const kbdSim = $("kbdSim");
const historyEl = $("history");
const splash = $("splash");

let U = 1;                                         // CSS px per mockup point
const measure = () => { U = phone.clientWidth / 393; };
measure();

/* ============================================================== motion */

/* Runs a spring and hands every value to `render`. Returns go(target, kick):
   retargeting mid-flight keeps the velocity, so anything can be interrupted.
   Reduced motion: a short linear fade to the target instead. */
function drive(spring, render, onRest) {
  let running = false;
  let fade = null;                                 // { from, to, t } while fading
  const task = (dt) => {
    if (fade) {
      fade.t += dt / 0.15;
      spring.value = lerp(fade.from, fade.to, clamp01(fade.t));
      spring.velocity = 0;
      if (fade.t >= 1) fade = null;
    } else {
      spring.step(dt);
    }
    render(spring.value);
    if (!fade && spring.settled) {
      running = false;
      if (onRest) onRest(spring.value);
      return false;
    }
    return true;
  };
  const go = (target, kick = 0) => {
    spring.to(target);
    if (reduce.matches) fade = { from: spring.value, to: target, t: 0 };
    else spring.velocity += kick;
    if (!running) {
      running = true;
      Animator.run(task);
    }
  };
  go.spring = spring;
  go.render = () => render(spring.value);
  return go;
}

const SOFT = { damping: 1, response: 0.4 };        // settles without overshoot
const SCREEN = { damping: 1, response: 0.5 };      // the big moves between screens
const BOUNCY = { damping: 0.6, response: 0.35 };   // a little overshoot

/* ============================================================== top bar */

function twoTone(inner) {
  return `<span class="tb-press"><span class="tb-dark">${inner}</span><span class="tb-light">${inner}</span></span>`;
}

$("btnHistory").innerHTML = twoTone(icon("history"));
$("btnSound").innerHTML = twoTone(`<span class="snd">${icon("sound-on", "snd-on")}${icon("sound-off", "snd-off")}</span>`);
$("histPlus").innerHTML = icon("plus");
$("histClose").innerHTML = icon("close");
$("kbarClose").innerHTML = icon("close");

const state = {
  mode: "idle",                                    // idle | gesture | voice | keys
  gestureOn: false,                                // recognition running (not paused)
  micOn: false,
  sound: true,
  historyOpen: false,
  before: "idle",                                  // where the keyboard was opened from
  chats: ["Чат #1", "Чат #2", "Чат #3", "Чат #4"], // TODO: функция будет добавлена позже (заглушки)
  current: 0,
};

function setTitle(text) {
  for (const el of $("title").children) el.textContent = text;
}

/* A press: squeeze to 0.92 and spring back. */
function pressable(button, target, depth = 0.08) {
  const go = drive(new Spring(0, { damping: 0.55, response: 0.28 }), (v) => {
    target.style.transform = `scale(${(1 - depth * v).toFixed(4)})`;
  });
  const down = () => go(1);
  const up = () => go(0);
  button.addEventListener("pointerdown", down);
  button.addEventListener("pointerup", up);
  button.addEventListener("pointercancel", up);
  button.addEventListener("pointerleave", up);
}
pressable($("btnHistory"), $("btnHistory").firstElementChild, 0.12);
pressable($("btnSound"), $("btnSound").firstElementChild, 0.12);

/* The sound icon. On: the arcs fan out of the speaker one after another.
   Off: they fold back and the slash is drawn. Both end as the original files. */
const sndOn = [...document.querySelectorAll(".snd-on")];
const sndOff = [...document.querySelectorAll(".snd-off")];
const goSound = drive(new Spring(1, SOFT), (v) => {
  for (const svg of sndOn) {
    svg.style.opacity = clamp01((v - 0.3) / 0.25).toFixed(3);
    const p = svg.querySelectorAll("path");
    p[1].style.strokeDashoffset = (1 - clamp01((v - 0.4) / 0.3)).toFixed(3);
    p[2].style.strokeDashoffset = (1 - clamp01((v - 0.62) / 0.38)).toFixed(3);
  }
  for (const svg of sndOff) {
    svg.style.opacity = clamp01((0.55 - v) / 0.25).toFixed(3);
    svg.querySelectorAll("path")[2].style.strokeDashoffset = clamp01(v / 0.45).toFixed(3);
  }
});
goSound.render();

$("btnSound").addEventListener("click", () => {
  state.sound = !state.sound;
  $("btnSound").setAttribute("aria-pressed", String(state.sound));
  goSound(state.sound ? 1 : 0);
  // TODO: функция будет добавлена позже (озвучка текста)
});

/* ================================================================ pills */

const pills = {};
for (const [key, id, inner] of [
  ["gesture", "pillGesture", (c) => icon("hand")],
  ["voice", "pillVoice", (c) => `<span class="mic">${icon("mic", "mic-on")}${icon("mic-off", "mic-off")}</span>`],
  ["keys", "pillKeys", (c) => icon("keyboard")],
]) {
  const el = $(id);
  el.innerHTML =
    `<span class="pill-body">` +
    `<span class="pill-fill dark"></span><span class="pill-inner"><span class="pill-fill light"></span></span>` +
    `<span class="pill-ring dark"></span><span class="pill-ring light"></span>` +
    `<span class="pill-icon dark">${inner()}</span><span class="pill-icon light">${inner()}</span>` +
    `</span>`;
  const pill = { el, press: 0, enter: 1, down: 0 };
  // one transform per pill: entrance from below, the dock leaving, the press
  pill.place = () => {
    const y = (pill.enter * 110 + pill.down * 130) * U;
    el.style.transform = `translate3d(0, ${y.toFixed(1)}px, 0) scale(${(1 - 0.08 * pill.press).toFixed(4)})`;
  };
  pill.goActive = drive(new Spring(0, { damping: 0.8, response: 0.38 }), (v) => el.style.setProperty("--a", clamp01(v).toFixed(3)));
  pill.goPress = drive(new Spring(0, { damping: 0.55, response: 0.28 }), (v) => { pill.press = v; pill.place(); });
  pill.goEnter = drive(new Spring(1, { damping: 0.75, response: 0.5 }), (v) => { pill.enter = v; pill.place(); });
  const up = () => pill.goPress(0);
  el.addEventListener("pointerdown", () => pill.goPress(1));
  el.addEventListener("pointerup", up);
  el.addEventListener("pointercancel", up);
  el.addEventListener("pointerleave", up);
  pill.place();
  pills[key] = pill;
}

/* The microphone: the slash is drawn across it or pulled back. */
const micOn = [...document.querySelectorAll(".mic-on")];
const micOff = [...document.querySelectorAll(".mic-off")];
const goMic = drive(new Spring(0, SOFT), (v) => {
  for (const svg of micOn) svg.style.opacity = clamp01((v - 0.45) / 0.3).toFixed(3);
  for (const svg of micOff) {
    svg.style.opacity = clamp01((0.75 - v) / 0.3).toFixed(3);
    svg.querySelectorAll("path")[4].style.strokeDashoffset = clamp01(v / 0.6).toFixed(3);
  }
});
goMic.render();

/* ============================================================== screens */

/* The camera block comes down from the top; the bar over it turns beige and
   the feed moves under it. */
const CAM_SHIFT = 317;                             // feed top: y 150 without the camera, 467 with
const goCam = drive(new Spring(0, SCREEN), (v) => {
  const hide = reduce.matches ? 0 : (1 - v) * 105;
  const t = `translate3d(0, ${(-hide).toFixed(2)}%, 0)`;
  camera.style.transform = t;
  camGlow.style.transform = t;
  camera.style.opacity = reduce.matches ? clamp01(v).toFixed(3) : "";
  camera.style.visibility = v > 0.002 ? "visible" : "hidden";
  camGlow.style.visibility = camera.style.visibility;
  chat.style.setProperty("--cam", clamp01(v).toFixed(3));
  // While it moves the feed keeps its tall box and is pushed down by
  // transform; at rest under the camera the box itself is made shorter.
  feed.style.transform = feed.classList.contains("under-cam") ? "" : `translate3d(0, ${(v * CAM_SHIFT * U).toFixed(1)}px, 0)`;
}, (v) => {
  if (v > 0.5) {
    feed.classList.add("under-cam");
    feed.style.top = `calc(var(--sat) + ${408}  * var(--u))`;
    feed.style.transform = "";
    scrollFeed(false);
  } else if (state.mode !== "gesture") {
    Capture.stop();                                // the camera is out of sight: release it
  }
});

function camWillMove() {
  if (feed.classList.contains("under-cam")) {
    feed.classList.remove("under-cam");
    feed.style.top = "";
    feed.style.transform = `translate3d(0, ${(goCam.spring.value * CAM_SHIFT * U).toFixed(1)}px, 0)`;
  }
}

/* The wave rises for the voice screen, and the pills over it turn beige. */
const goWave = drive(new Spring(0, SCREEN), (v) => {
  const hide = reduce.matches ? 0 : (1 - v) * 112;
  wave.style.transform = `translate3d(0, ${hide.toFixed(2)}%, 0)`;
  wave.style.opacity = reduce.matches ? clamp01(v).toFixed(3) : "";
  wave.style.visibility = v > 0.002 ? "visible" : "hidden";
  const w = clamp01(v).toFixed(3);
  for (const k in pills) pills[k].el.style.setProperty("--w", w);
});

/* The keyboard strip comes up as the dock goes down. */
const goKeys = drive(new Spring(0, SOFT), (v) => {
  const hide = reduce.matches ? 0 : (1 - v) * 115;
  kbar.style.transform = `translate3d(0, ${hide.toFixed(2)}%, 0)`;
  kbar.style.opacity = reduce.matches ? clamp01(v).toFixed(3) : "";
  kbar.style.visibility = v > 0.002 ? "visible" : "hidden";
  for (const k in pills) { pills[k].down = clamp01(v); pills[k].place(); }
  dock.style.pointerEvents = v > 0.5 ? "none" : "";
});

/* «Чтобы начать чат…»: comes up from below, leaves upwards. */
let introShown = false;
const goIntro = drive(new Spring(0, SOFT), (v) => {
  const a = clamp01(v);
  const y = reduce.matches ? 0 : (introShown ? (1 - a) * 14 : -(1 - a) * 14) * U;
  intro.style.opacity = a.toFixed(3);
  intro.style.transform = `translate3d(0, ${y.toFixed(1)}px, 0)`;
});

function refreshIntro() {
  const want = state.mode === "idle" && Feed.count === 0;
  if (want === introShown) return;
  introShown = want;
  goIntro(want ? 1 : 0);
}

function refreshFeedBox() {
  // How far the feed's bottom edge stands off the bottom of the screen.
  let b = "calc(var(--sab) + 83 * var(--u))";                       // above the pills
  if (state.mode === "voice") b = "calc(var(--sab) + 131 * var(--u))";   // above the wave
  if (state.mode === "keys") b = `calc(var(--kb) + ${kbar.offsetHeight / U + 6} * var(--u))`;
  feed.style.bottom = b;
}

function refreshPills() {
  const g = state.mode === "gesture" && state.gestureOn;
  const v = state.mode === "voice" && state.micOn;
  pills.gesture.goActive(g ? 1 : 0);
  pills.voice.goActive(v ? 1 : 0);
  pills.keys.goActive(state.mode === "keys" ? 1 : 0);
  pills.gesture.el.setAttribute("aria-pressed", String(g));
  pills.voice.el.setAttribute("aria-pressed", String(v));
  pills.keys.el.setAttribute("aria-pressed", String(state.mode === "keys"));
  pills.gesture.el.classList.toggle("breathing", g);
  goMic(state.micOn ? 1 : 0);
}

function setMode(next) {
  const prev = state.mode;
  if (next === prev) return;
  state.mode = next;

  if (prev === "gesture") {
    Capture.pause();                               // the camera is released once it has slid away
    Feed.closePhrase();
    setGlow(false);
    showPlaque(null);
  }
  if (prev === "voice") { state.micOn = false; Voice.stop(); }
  if (prev === "keys") { kbarInput.blur(); kbdSim.classList.remove("on"); }

  if (next === "gesture") { state.gestureOn = true; Capture.start(); }
  if (next === "voice") { state.micOn = true; Voice.start(); }
  if (next === "keys") {
    state.before = prev;
    kbdSim.classList.add("on");
    kbar.style.visibility = "visible";             // a hidden field cannot take the focus
    kbarInput.focus({ preventScroll: true });
  }

  camWillMove();
  goCam(next === "gesture" ? 1 : 0);
  goWave(next === "voice" ? 1 : 0);
  goKeys(next === "keys" ? 1 : 0);
  refreshKeyboardInset();
  refreshFeedBox();
  refreshPills();
  refreshIntro();
  scrollFeed(true);
}

pills.gesture.el.addEventListener("click", () => {
  if (state.mode !== "gesture") return setMode("gesture");
  // pressed again: pause, the picture stays
  state.gestureOn = !state.gestureOn;
  if (state.gestureOn) Capture.start();
  else { Capture.pause(); Feed.closePhrase(); setGlow(false); showPlaque(null); }
  refreshPills();
});

pills.voice.el.addEventListener("click", () => {
  if (state.mode !== "voice") return setMode("voice");
  state.micOn = !state.micOn;
  if (state.micOn) Voice.start(); else Voice.stop();
  refreshPills();
});

pills.keys.el.addEventListener("click", () => setMode("keys"));

/* =============================================================== camera */

let personSeen = false;
function setGlow(on) {
  personSeen = on;
  camGlow.classList.toggle("on", on && state.mode === "gesture" && state.gestureOn);
}

/* The hint slides up into the camera; on a new text it fades and returns. */
let plaqueWant = null;
let plaqueHas = null;
const goPlaque = drive(new Spring(0, { damping: 0.85, response: 0.32 }), (v) => {
  const a = clamp01(v);
  plaque.style.opacity = a.toFixed(3);
  plaque.style.transform = reduce.matches ? "" : `translate3d(0, ${((1 - a) * 16 * U).toFixed(1)}px, 0)`;
}, (v) => {
  if (v < 0.5 && plaqueWant) {                     // out: bring the next text in
    plaqueHas = plaqueWant;
    plaqueText.textContent = plaqueHas;
    goPlaque(1);
  }
});

function showPlaque(text) {
  plaqueWant = text;
  if (!text) { plaqueHas = null; return goPlaque(0); }
  if (text === plaqueHas) return goPlaque(1);
  if (plaqueHas === null || goPlaque.spring.value < 0.05) {
    plaqueHas = text;
    plaqueText.textContent = text;
    return goPlaque(1);
  }
  plaqueHas = "";                                  // fade the old one out first
  goPlaque(0);
}

/* ================================================================= feed */

function scrollFeed(smooth) {
  requestAnimationFrame(() => {
    feed.scrollTo({ top: feed.scrollHeight, behavior: smooth && !reduce.matches ? "smooth" : "auto" });
  });
}

const TAIL = `<svg class="tail" viewBox="157 19 22 25" aria-hidden="true">${ICONS.bubble.body.replace(/<rect[^>]*>/, "")}</svg>`;

const Feed = (() => {
  let count = 0;
  let open = null;                                 // the gesture bubble still taking words
  let phraseTimer = 0;
  let ghostTimer = 0;
  const PHRASE_GAP = 2000;                         // a pause this long ends the phrase

  /* A bubble grows out of its tail: scale 0.8 -> 1 with a little overshoot. */
  function bubble(side, appear = true) {
    const el = document.createElement("div");
    el.className = "msg " + side;
    el.innerHTML = `<div class="bubble"><span class="bubble-text"></span></div>${TAIL}`;
    feedInner.appendChild(el);
    count++;
    const m = { el, body: el.firstChild, text: el.firstChild.firstChild, dots: null, words: 0 };
    if (appear) {
      drive(new Spring(0, BOUNCY), (v) => {
        el.style.opacity = clamp01(v * 1.6).toFixed(3);
        el.style.transform = reduce.matches ? "" : `scale(${(0.8 + 0.2 * v).toFixed(4)})`;
      })(1);
    }
    refreshIntro();
    scrollFeed(true);
    return m;
  }

  /* The bubble's width follows its text smoothly instead of jumping. This is
     the one place a size is animated; the element is a few dozen pixels.
     One spring per bubble: a second change while it is still growing only
     moves the target, so the text is never squeezed into breaking a word. */
  function grow(m, change) {
    const w0 = m.body.offsetWidth, h0 = m.body.offsetHeight;
    m.body.style.width = "";
    m.text.style.whiteSpace = "";
    change();
    const w1 = m.body.offsetWidth, h1 = m.body.offsetHeight;
    if (reduce.matches || w1 === w0 || h1 !== h0) {
      if (m.goWidth) m.goWidth.spring.set(w1).to(w1);
      return;
    }
    if (!m.goWidth) {
      m.goWidth = drive(new Spring(w0, { damping: 0.9, response: 0.3, precision: 0.3 }), (w) => {
        if (m.growing) m.body.style.width = w.toFixed(1) + "px";
      }, () => {
        m.growing = false;
        m.body.style.width = "";
        m.text.style.whiteSpace = "";
      });
    }
    m.growing = true;
    m.goWidth.spring.set(w0);
    m.body.style.width = w0 + "px";
    m.text.style.whiteSpace = "nowrap";
    m.goWidth(w1);
  }

  function setDots(m, on) {
    if (on === Boolean(m.dots)) return;
    grow(m, () => {
      if (on) {
        m.dots = document.createElement("span");
        m.dots.className = "dots";
        m.dots.innerHTML = "<i></i><i></i><i></i>";
        m.text.appendChild(m.dots);
      } else {
        m.dots.remove();
        m.dots = null;
      }
    });
  }

  /* A word rises 6 points into place. */
  function word(m, text) {
    const w = document.createElement("span");
    w.className = "w";
    w.textContent = text;
    grow(m, () => m.text.insertBefore(w, m.dots));
    m.words++;
    drive(new Spring(0, SOFT), (v) => {
      w.style.opacity = clamp01(v).toFixed(3);
      w.style.transform = reduce.matches ? "" : `translate3d(0, ${((1 - v) * 6 * U).toFixed(1)}px, 0)`;
    })(1);
    scrollFeed(true);
  }

  function remove(m) {
    count--;
    drive(new Spring(1, SOFT), (v) => {
      m.el.style.opacity = clamp01(v).toFixed(3);
      m.el.style.transform = reduce.matches ? "" : `scale(${(0.8 + 0.2 * v).toFixed(4)})`;
    }, () => { m.el.remove(); refreshIntro(); })(0);
  }

  /* Gestures: words join the open bubble; two seconds of silence close it. */
  function gestureWord(text) {
    clearTimeout(ghostTimer);
    if (!open) { open = bubble("right"); setDots(open, true); }
    word(open, text);
    clearTimeout(phraseTimer);
    phraseTimer = setTimeout(closePhrase, PHRASE_GAP);
  }

  /* The model sees a sign taking shape: three dots, as in a messenger. If no
     word comes of it, the empty bubble goes away again. */
  function listening(on) {
    clearTimeout(ghostTimer);
    if (on) {
      if (!open) ghostTimer = setTimeout(() => { if (!open) { open = bubble("right"); setDots(open, true); } }, 400);
    } else if (open && open.words === 0) {
      ghostTimer = setTimeout(() => { if (open && open.words === 0) { remove(open); open = null; } }, 1500);
    }
  }

  function closePhrase() {
    clearTimeout(phraseTimer);
    clearTimeout(ghostTimer);
    if (!open) return;
    if (open.words === 0) remove(open); else setDots(open, false);
    open = null;
  }

  /* A whole message at once, on the left (voice and keyboard). */
  function say(text, appear = true) {
    const m = bubble("left", appear);
    m.text.textContent = text;
    return m;
  }

  function clear() {
    closePhrase();
    feedInner.textContent = "";
    count = 0;
    refreshIntro();
  }

  return { bubble, word, setDots, remove, gestureWord, listening, closePhrase, say, clear, get count() { return count; } };
})();

Capture.onWord = (label) => {
  if (state.mode === "gesture" && state.gestureOn) Feed.gestureWord(label);
};
Capture.onListening = (on) => {
  if (state.mode === "gesture" && state.gestureOn) Feed.listening(on);
};
Capture.onMessage = (text) => showPlaque(state.mode === "gesture" ? text : null);
Capture.onPerson = (seen) => setGlow(seen);

/* ================================================================ voice */

/* TODO: функция будет добавлена позже (распознавание речи).
   For now the screen only shows how it will look: a bubble on the left with
   three dots, then a demo line arriving word by word. No microphone is used. */
const Voice = (() => {
  const DEMO = "Здравствуйте! Это пример текста из голоса.";
  let timers = [];
  let shown = false;
  let m = null;

  function start() {
    if (shown) return;                             // the demo plays once per chat
    shown = true;
    timers.push(setTimeout(() => {
      m = Feed.bubble("left");
      Feed.setDots(m, true);
      DEMO.split(" ").forEach((w, i, all) => {
        timers.push(setTimeout(() => {
          Feed.word(m, w);
          if (i === all.length - 1) timers.push(setTimeout(() => Feed.setDots(m, false), 500));
        }, 700 + i * 320));
      });
    }, 500));
  }

  function stop() {
    timers.forEach(clearTimeout);
    timers = [];
    if (m && m.dots) Feed.setDots(m, false);
  }

  return { start, stop, reset() { stop(); shown = false; m = null; } };
})();

/* ============================================================= keyboard */

/* The strip rides on top of the on-screen keyboard, wherever that is. */
function refreshKeyboardInset() {
  let kb = 0;
  const vv = window.visualViewport;
  if (vv) kb = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
  if (document.documentElement.classList.contains("sim") && state.mode === "keys") kb = 335 * U;
  document.documentElement.style.setProperty("--kb", kb.toFixed(1) + "px");
}
if (window.visualViewport) {
  visualViewport.addEventListener("resize", () => { refreshKeyboardInset(); refreshFeedBox(); });
  visualViewport.addEventListener("scroll", () => { refreshKeyboardInset(); window.scrollTo(0, 0); });
}

function fitInput() {
  kbarInput.style.height = "auto";
  kbarInput.style.height = Math.min(kbarInput.scrollHeight, 104 * U) + "px";
  refreshFeedBox();
}
kbarInput.addEventListener("input", fitInput);

/* Enter sends: the text takes off from the strip and lands in the feed as a
   bubble on the left. */
function sendTyped() {
  const text = kbarInput.value.trim();
  if (!text) return;
  const from = kbarInput.getBoundingClientRect();
  kbarInput.value = "";
  fitInput();
  // TODO: функция будет добавлена позже (сообщение нигде не сохраняется)
  const m = Feed.say(text, reduce.matches);
  if (reduce.matches) return;
  const to = m.el.getBoundingClientRect();
  const dx = from.left - to.left, dy = from.top - to.top;
  drive(new Spring(1, { damping: 0.8, response: 0.42 }), (v) => {
    m.el.style.transform = `translate3d(${(dx * v).toFixed(1)}px, ${(dy * v).toFixed(1)}px, 0)`;
  })(0);
}

kbarInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    sendTyped();
  } else if (e.key === "Escape") {
    closeKeys();
  }
});

/* The cross turns a quarter and the strip goes down with the keyboard. */
const goKbarClose = drive(new Spring(0, BOUNCY), (v) => {
  $("kbarClose").firstElementChild.style.transform = `rotate(${(v * 90).toFixed(1)}deg)`;
});
function closeKeys() {
  goKbarClose.spring.set(0);
  goKbarClose(1);
  setMode(state.before === "keys" ? "idle" : state.before);
}
$("kbarClose").addEventListener("click", closeKeys);

/* ============================================================== history */

/* TODO: функция будет добавлена позже (история чатов).
   The list is a placeholder: nothing is stored, renamed or deleted, and
   choosing a chat only returns to the start screen. */
const Wheel = (() => {
  const el = $("wheel");
  const box = $("wheelItems");
  const STEP = 43;                                 // points between rows
  let rows = [];                                   // { el, grow }
  const pos = new Spring(0, { damping: 0.85, response: 0.45, precision: 0.001 });

  function render() {
    let at = 0;                                    // rows before this one, counting a growing row in part
    for (const r of rows) {
      const d = at + (r.grow - 1) / 2 - pos.value;
      at += r.grow;
      const ad = Math.abs(d);
      // 38 pt in the centre, 30 pt one row away, smaller and fainter beyond
      const size = ad <= 1 ? lerp(38, 30, ad) : Math.max(16, 30 - 6 * (ad - 1));
      const alpha = ad <= 1 ? lerp(1, 0.7, ad) : Math.max(0, 0.7 - 0.4 * (ad - 1));
      const tilt = reduce.matches ? 0 : Math.max(-62, Math.min(62, -d * 16));
      const y = d * STEP * U * (1 - 0.03 * Math.min(ad, 3));
      r.el.style.opacity = (alpha * r.grow).toFixed(3);
      r.el.style.transform =
        `translate3d(0, ${y.toFixed(1)}px, 0) rotateX(${tilt.toFixed(1)}deg) scale(${(size / 38 * (0.6 + 0.4 * r.grow)).toFixed(4)})`;
      r.el.style.visibility = alpha > 0.01 ? "visible" : "hidden";
      r.el.setAttribute("aria-selected", String(ad < 0.5));
    }
  }

  const go = drive(pos, render);

  function build(names, current) {
    box.textContent = "";
    rows = names.map((name) => {
      const item = document.createElement("div");
      item.className = "wheel-item";
      item.setAttribute("role", "option");
      item.textContent = name;
      box.appendChild(item);
      return { el: item, grow: 1 };
    });
    pos.set(current).to(current);
    pos.velocity = 0;
    render();
  }

  const centre = () => Math.max(0, Math.min(rows.length - 1, Math.round(pos.value)));

  /* Drag with inertia, then settle softly on a row. Past either end the list
     resists, like a rubber band. */
  let drag = null;
  el.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    el.setPointerCapture(e.pointerId);
    drag = { id: e.pointerId, y: e.clientY, at: pos.value, moved: 0, v: 0, t: e.timeStamp, lastY: e.clientY };
    pos.to(pos.value);
    pos.velocity = 0;
  });
  el.addEventListener("pointermove", (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const dy = e.clientY - drag.y;
    drag.moved = Math.max(drag.moved, Math.abs(dy));
    let p = drag.at - dy / (STEP * U);
    const max = rows.length - 1;
    if (p < 0) p *= 0.35; else if (p > max) p = max + (p - max) * 0.35;
    const dt = Math.max(1, e.timeStamp - drag.t) / 1000;
    drag.v = lerp(drag.v, -(e.clientY - drag.lastY) / (STEP * U) / dt, 0.5);
    drag.t = e.timeStamp;
    drag.lastY = e.clientY;
    pos.set(p).to(p);
    render();
  });
  const release = (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const d = drag;
    drag = null;
    if (d.moved < 6 * U) return tap(e);
    const target = Math.max(0, Math.min(rows.length - 1, Math.round(pos.value + d.v * 0.22)));
    pos.velocity = reduce.matches ? 0 : d.v;
    go(target);
  };
  el.addEventListener("pointerup", release);
  el.addEventListener("pointercancel", release);

  function tap(e) {
    const r = el.getBoundingClientRect();
    const off = Math.round((e.clientY - (r.top + r.height / 2)) / (STEP * U));
    const i = Math.max(0, Math.min(rows.length - 1, centre() + off));
    if (off === 0) choose(i); else go(i);
  }

  el.addEventListener("wheel", (e) => {
    e.preventDefault();
    go(Math.max(0, Math.min(rows.length - 1, Math.round(pos.target + Math.sign(e.deltaY)))));
  }, { passive: false });

  el.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") go(Math.min(rows.length - 1, Math.round(pos.target) + 1));
    else if (e.key === "ArrowUp") go(Math.max(0, Math.round(pos.target) - 1));
    else if (e.key === "Enter") choose(centre());
    else return;
    e.preventDefault();
  });

  let choose = () => {};

  /* A new chat opens up in the middle of the wheel, pushing the rest apart. */
  function insert(name, done) {
    const i = centre() + 1;
    const item = document.createElement("div");
    item.className = "wheel-item";
    item.setAttribute("role", "option");
    item.textContent = name;
    box.insertBefore(item, rows[i] ? rows[i].el : null);
    const row = { el: item, grow: reduce.matches ? 1 : 0 };
    rows.splice(i, 0, row);
    go(i);
    drive(new Spring(row.grow, { damping: 0.7, response: 0.45 }), (v) => { row.grow = clamp01(v); render(); }, done)(1);
    return i;
  }

  return { build, insert, render, set onChoose(fn) { choose = fn; } };
})();

/* The history slides up from the bottom; the chat behind it steps back a
   little and comes forward again when it closes. */
const goHistory = drive(new Spring(0, SCREEN), (v) => {
  const hide = reduce.matches ? 0 : (1 - v) * 102;
  historyEl.style.transform = `translate3d(0, ${hide.toFixed(2)}%, 0)`;
  historyEl.style.opacity = reduce.matches ? clamp01(v).toFixed(3) : "";
  historyEl.style.visibility = v > 0.002 ? "visible" : "hidden";
  chat.style.transform = reduce.matches ? "" : `scale(${(1 - 0.04 * clamp01(v)).toFixed(4)})`;
});

function openHistory() {
  if (state.historyOpen) return;
  state.historyOpen = true;
  if (state.mode === "keys") closeKeys();
  historyEl.setAttribute("aria-hidden", "false");
  Wheel.build(state.chats, state.current);
  goHistory(1);
}

function closeHistory() {
  if (!state.historyOpen) return;
  state.historyOpen = false;
  historyEl.setAttribute("aria-hidden", "true");
  goHistory(0);
}

function openChat(index) {
  // TODO: функция будет добавлена позже (чаты не сохраняются: выбранный чат открывается пустым)
  if (index !== state.current) {
    state.current = index;
    setTitle(state.chats[index]);
    Feed.clear();
    Voice.reset();
  }
  setMode("idle");
  closeHistory();
}

Wheel.onChoose = openChat;
$("btnHistory").addEventListener("click", openHistory);

const goClose = drive(new Spring(0, BOUNCY), (v) => {
  $("histClose").firstElementChild.style.transform = `rotate(${(v * 90).toFixed(1)}deg)`;
});
$("histClose").addEventListener("click", () => {
  goClose.spring.set(0);
  goClose(1);
  closeHistory();
});

/* «+» turns a quarter; the new chat unfolds in the wheel, then opens. */
let plusTurns = 0;
const goPlus = drive(new Spring(0, BOUNCY), (v) => {
  $("histPlus").firstElementChild.style.transform = `rotate(${(v * 90).toFixed(1)}deg)`;
});
let adding = false;
$("histPlus").addEventListener("click", () => {
  if (adding) return;
  adding = true;
  goPlus(++plusTurns);
  const name = `Чат #${state.chats.length + 1}`;
  const i = Wheel.insert(name, () => {
    setTimeout(() => { adding = false; openChat(i); }, 260);
  });
  state.chats.splice(i, 0, name);
  if (i <= state.current) state.current++;
});

/* =============================================================== splash */

/* Both marks are drawn as if by a pen, and end up exactly as their files.
   The house is made of strokes: its own paths are drawn. The figure is one
   filled shape: it stays as it is and is uncovered through a mask, by wide
   "brush" strokes that run along the middle of each part. */
function runSplash(done) {
  const house = $("logoHouse");
  const access = $("logoAccess");
  house.innerHTML = icon("logo-house");
  const brush = (d, width, cap = "round") =>
    `<path pathLength="1" d="${d}" stroke-width="${width}" stroke-linecap="${cap}"/>`;
  access.innerHTML =
    `<svg class="ic" viewBox="${ICONS["logo-access"].box}" fill="none" aria-hidden="true">` +
    `<defs><mask id="pen" maskUnits="userSpaceOnUse" x="-5" y="-5" width="115" height="115">` +
    `<g class="brush" stroke="#fff" fill="none" stroke-linejoin="round">` +
    brush("M52.5 4.3A48.2 48.2 0 1 1 52.49 4.3", 13, "butt") +          // the ring, clockwise from the top
    brush("M52.5 21.2A4.1 4.1 0 1 1 52.49 21.2", 9.4) +                  // the head, drawn and filled
    brush("M25 36.7L44 40.2Q52.5 41.4 61 40.2L80 36.7", 14) +            // arms: left hand, shoulders, right hand
    brush("M52.5 39.5L52.5 63.5", 25, "butt") +                          // the body, down from the shoulders
    brush("M50 60L40.3 84.2", 14) + brush("M55.2 60L65.4 84.2", 14) +    // both legs at once
    `</g></mask></defs><g mask="url(#pen)">${ICONS["logo-access"].body}</g></svg>`;

  const finish = () => {
    splash.classList.add("drawn");
    const g = access.querySelector("g[mask]");
    if (g) g.removeAttribute("mask");              // what is left is the original drawing
    const defs = access.querySelector("defs");
    if (defs) defs.remove();
  };

  const leave = () => {
    finish();
    const row = $("splashRow");
    // the marks shrink and melt, the burgundy goes up, the start screen is under it
    drive(new Spring(0, SOFT), (v) => {
      row.style.opacity = (1 - clamp01(v)).toFixed(3);
      row.style.transform = reduce.matches ? "" : `scale(${(1 - 0.25 * v).toFixed(4)})`;
    })(1);
    drive(new Spring(0, { damping: 1, response: 0.55 }), (v) => {
      if (reduce.matches) splash.style.opacity = (1 - clamp01(v)).toFixed(3);
      else splash.style.transform = `translate3d(0, ${(-v * 103).toFixed(2)}%, 0)`;
    }, () => { splash.remove(); })(1);
    done();
  };

  if (reduce.matches || params.has("nosplash")) {
    finish();
    return setTimeout(leave, params.has("nosplash") ? 0 : 600);
  }

  const draw = (path, start, ms, easing = "ease-out") =>
    path.animate(
      [{ strokeDashoffset: 1, opacity: 0 }, { opacity: 1, offset: 0.04 }, { strokeDashoffset: 0, opacity: 1 }],
      { delay: start, duration: ms, easing, fill: "both" });

  // 1. the house: the roof in one line, then the strokes left to right, like rain
  const hp = [...house.querySelectorAll("path")];
  draw(hp[0], 0, 450, "cubic-bezier(0.45, 0, 0.3, 1)");
  [3, 2, 1, 4, 5, 6, 7, 8].forEach((k, i) => draw(hp[k], 400 + i * 70, 200));

  // 2. the figure in a circle, from when the house is about half drawn
  const bp = [...access.querySelectorAll(".brush path")];
  const T = 520;
  draw(bp[0], T, 500, "cubic-bezier(0.4, 0, 0.3, 1)");
  draw(bp[1], T + 470, 160);
  draw(bp[2], T + 590, 170);
  draw(bp[3], T + 710, 150);
  draw(bp[4], T + 820, 160);
  draw(bp[5], T + 820, 160);

  // 3. one soft pulse, 4. away
  const pulse = $("splashRow").animate(
    [{ transform: "scale(1)" }, { transform: "scale(1.04)" }, { transform: "scale(1)" }],
    { delay: 1520, duration: 300, easing: "ease-in-out" });
  pulse.onfinish = leave;
}

/* ================================================================ start */

setTitle(state.chats[state.current]);

// the wavy edge: seven waves over two screen widths (3.5 a screen), amplitude 10
{
  let d = "M0 24";
  for (let x = 0; x <= 786; x += 3) d += `L${x} ${(12 - 11 * Math.sin((x / (786 / 7)) * 2 * Math.PI + 0.6)).toFixed(2)}`;
  $("wavePath").setAttribute("d", d + "L786 24Z");
}

goCam.render();
goWave.render();
goKeys.render();
goHistory.render();
goIntro.render();
goPlaque.render();
refreshPills();
Capture.init(video);

runSplash(() => {
  // the pills come up from below, left to right
  ["gesture", "voice", "keys"].forEach((k, i) => setTimeout(() => pills[k].goEnter(0), 120 + i * 60));
  setTimeout(refreshIntro, 250);
  // ?screen=gesture|voice|keys|history opens that screen at once (for checking against the mockup)
  const first = params.get("screen");
  if (first === "history") openHistory();
  else if (["gesture", "voice", "keys"].includes(first)) setMode(first);
});

function relayout() {
  measure();
  for (const k in pills) pills[k].place();
  goCam.render();
  goPlaque.render();
  refreshKeyboardInset();
  refreshFeedBox();
  Wheel.render();
}
addEventListener("resize", relayout);
reduce.addEventListener("change", relayout);
if (document.fonts && document.fonts.ready) document.fonts.ready.then(relayout);

/* ?debug shows, in a corner, what the model is given and its best guesses. */
if (params.has("debug")) {
  const box = document.createElement("div");
  box.className = "debug";
  const cv = document.createElement("canvas");
  cv.width = cv.height = 224;
  const txt = document.createElement("pre");
  box.append(cv, txt);
  document.body.append(box);
  const c = cv.getContext("2d");
  setInterval(() => {
    const st = Capture.stats;
    const r = st.crop;
    if (r && video.videoWidth) c.drawImage(video, r.x, r.y, r.w, r.h, 0, 0, 224, 224);
    txt.textContent =
      (st.top || []).slice(0, 3).map((t) => `${(t.p * 100).toFixed(0).padStart(3)}%  ${t.label}`).join("\n") +
      (Capture.online
        ? `\nсервер · ${st.fps.toFixed(0)} к/с · ${st.ms} мс`
        : `\nустройство · ${st.fps.toFixed(0)} к/с · ${Math.round(st.inferMs)} мс`) +
      (Framer.info.crop ? "\nчеловек найден" : "\nкадр по экрану");
  }, 200);
}

/* The offline cache holds a whole version of the app, which is exactly what
   makes it unusable while that version is being written: every edit would be
   served from the previous copy. It is switched off on a development machine.
   The iOS app has all its files inside it and has no use for a cache at all. */
const LOCAL = ["localhost", "127.0.0.1", "::1"].includes(location.hostname);
if ("serviceWorker" in navigator && !LOCAL && !Platform.native) {
  addEventListener("load", () => {
    navigator.serviceWorker.register("sw.js", { updateViaCache: "none" })
      .then((reg) => reg.update())                 // look for a new version on every open
      .catch(() => {});
  });
}
