/* The pose model, off the main thread: on a busy device one pass takes tens
   of milliseconds, which on the page's own thread would stall animations and
   the camera clock. A classic worker on purpose - MediaPipe loads its wasm
   with importScripts, which module workers do not have; the bundle itself
   comes in through a dynamic import, which classic workers do.

   In:  { init: baseUrl }  then  { bitmap, t }  (a small copy of the frame)
   Out: { ready: true } | { failed: message } | { points, ms }
        points: nose and both shoulders as { x, y, v } fractions of the frame,
        or null when nobody was found. */

let landmarker = null;

self.onmessage = async (e) => {
  const d = e.data;
  if (d.init) {
    try {
      const { FilesetResolver, PoseLandmarker } = await import(d.init + "vendor/mediapipe/vision_bundle.mjs");
      const fileset = await FilesetResolver.forVisionTasks(d.init + "vendor/mediapipe/wasm");
      landmarker = await PoseLandmarker.createFromOptions(fileset, {
        baseOptions: { modelAssetPath: d.init + "model/pose_landmarker_lite.task", delegate: "CPU" },
        runningMode: "VIDEO",
        numPoses: 1,
      });
      self.postMessage({ ready: true });
    } catch (err) {
      self.postMessage({ failed: String((err && err.message) || err) });
    }
    return;
  }
  if (!d.bitmap) return;
  if (!landmarker) { d.bitmap.close(); return; }
  const t0 = performance.now();
  let points = null;
  try {
    const r = landmarker.detectForVideo(d.bitmap, d.t);
    const p = r && r.landmarks && r.landmarks[0];
    if (p) {
      const pick = (k) => ({ x: p[k].x, y: p[k].y, v: p[k].visibility ?? 1 });
      points = { nose: pick(0), ls: pick(11), rs: pick(12) };
    }
  } catch (err) {
    /* a frame it could not read; the next one will do */
  }
  d.bitmap.close();
  self.postMessage({ points, ms: performance.now() - t0 });
};
