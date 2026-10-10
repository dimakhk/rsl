/* Recognition on a GPU server (SignFlow-R), when one is reachable.

   SignFlow-R recognises more surely than the S3D model that runs in this
   device, but it is far too heavy for a tablet (1.4 s a window on a laptop,
   0.38 s on a server's Tesla T4). So the tablet does what it is good at -
   camera, finding the person, cropping - and sends small frames; the server
   answers with words.

   Which server: the "url" in server.json next to this file (or ?server=...).
   No server, or the connection drops: the app carries on with the model in
   the device, and comes back to the server when it answers again.

   Frames: the crop, letterboxed into 224x224 on grey (114) as the model was
   trained, JPEG, 15 a second - SignFlow-R reads every second frame of a
   30 fps video. About 0.6 Mbit/s. */

const Cloud = (() => {
  const SIDE = 224;
  const RETRY_MS = 3000;
  const MAX_IN_FLIGHT = 2;
  const MAX_BUFFERED = 256 * 1024;                // bytes waiting in the socket: we are behind

  let url = null;
  let ws = null;
  let retry = 0;
  let encoder = null;                             // Worker
  let inFlight = 0;
  let running = false;
  let tick = 0;

  const stats = { online: false, model: "", ms: 0, lag: 0, top: [], crop: null, fps: 0 };
  const sent = [];
  let onWord = () => {};
  let onStats = () => {};

  /* Letterbox and JPEG off the main thread. */
  const ENCODER = `
    const SIDE = ${SIDE};
    let canvas = null, ctx = null;
    onmessage = async (e) => {
      const { bitmap, t } = e.data;
      if (!canvas) { canvas = new OffscreenCanvas(SIDE, SIDE); ctx = canvas.getContext("2d"); }
      const s = SIDE / Math.max(bitmap.width, bitmap.height);
      const w = Math.max(1, Math.round(bitmap.width * s)), h = Math.max(1, Math.round(bitmap.height * s));
      ctx.fillStyle = "rgb(114,114,114)";
      ctx.fillRect(0, 0, SIDE, SIDE);
      ctx.drawImage(bitmap, (SIDE - w) >> 1, (SIDE - h) >> 1, w, h);
      bitmap.close();
      try {
        const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.8 });
        const jpg = new Uint8Array(await blob.arrayBuffer());
        const packet = new Uint8Array(8 + jpg.length);
        new DataView(packet.buffer).setFloat64(0, t, true);
        packet.set(jpg, 8);
        postMessage({ packet: packet.buffer }, [packet.buffer]);
      } catch (err) {
        postMessage({ failed: true });
      }
    };`;

  function ensureEncoder() {
    if (encoder) return encoder;
    encoder = new Worker(URL.createObjectURL(new Blob([ENCODER], { type: "text/javascript" })));
    encoder.onmessage = (e) => {
      inFlight = Math.max(0, inFlight - 1);
      if (e.data.packet && running && stats.online) {
        ws.send(e.data.packet);
        const now = performance.now();
        sent.push(now);
        while (sent.length > 30) sent.shift();
        if (sent.length > 1) stats.fps = (sent.length - 1) * 1000 / (now - sent[0]);
      }
    };
    encoder.onerror = () => { inFlight = 0; };
    return encoder;
  }

  function connect() {
    clearTimeout(retry);
    if (!url) return;
    try {
      ws = new WebSocket(url);
    } catch (e) {
      retry = setTimeout(connect, RETRY_MS);
      return;
    }
    ws.binaryType = "arraybuffer";
    ws.onopen = () => {
      stats.online = true;
      if (running) ws.send("reset");
      onStats(stats);
    };
    ws.onclose = () => {
      stats.online = false;
      onStats(stats);
      retry = setTimeout(connect, RETRY_MS);
    };
    ws.onerror = () => { /* onclose follows */ };
    ws.onmessage = (e) => {
      let d;
      try { d = JSON.parse(e.data); } catch (err) { return; }
      if (d.t === "word") {
        if (running) onWord(d.label, d.p);
      } else if (d.t === "top") {
        stats.ms = d.ms;
        stats.lag = d.lag;
        stats.top = d.top.map(([i, label, p]) => ({ label: label || "№" + i, p }));
        onStats(stats);
      }
    };
  }

  /* Reads server.json (never from a cache) and connects. Without a server
     configured this does nothing and the app stays on the device's model. */
  async function init() {
    const q = new URLSearchParams(location.search).get("server");
    if (q === "0") return;                        // ?server=0: the device's model only
    try {
      if (q) {
        url = /^wss?:\/\//.test(q) ? q : `wss://${q}/ws`;
      } else {
        const cfg = await (await fetch("server.json", { cache: "no-store" })).json();
        url = cfg.url || null;
        stats.model = cfg.model || "";
      }
    } catch (e) {
      url = null;
    }
    if (url && typeof OffscreenCanvas !== "undefined" && typeof createImageBitmap === "function") {
      ensureEncoder();
      connect();
    }
  }

  /* Called for every captured frame (30 a second); every second one is sent. */
  function pushFrame(video, crop) {
    if (!running || !stats.online) return;
    if (video.readyState < 2 || !video.videoWidth) return;
    if (tick++ % 2) return;
    if (inFlight >= MAX_IN_FLIGHT || ws.bufferedAmount > MAX_BUFFERED) return;
    const vw = video.videoWidth, vh = video.videoHeight;
    const r = crop || { x: 0, y: 0, w: vw, h: vh };
    const x = Math.max(0, Math.min(vw - 2, Math.round(r.x)));
    const y = Math.max(0, Math.min(vh - 2, Math.round(r.y)));
    const w = Math.max(2, Math.min(vw - x, Math.round(r.w)));
    const h = Math.max(2, Math.min(vh - y, Math.round(r.h)));
    stats.crop = { x, y, w, h };
    inFlight++;
    createImageBitmap(video, x, y, w, h)
      .then((bitmap) => encoder.postMessage({ bitmap, t: Date.now() }, [bitmap]))
      .catch(() => { inFlight = Math.max(0, inFlight - 1); });
  }

  function start() {
    running = true;
    tick = 0;
    inFlight = 0;
    sent.length = 0;
    stats.top = [];
    if (stats.online) ws.send("reset");
  }

  function stop() {
    running = false;
  }

  return {
    init, start, stop, pushFrame, stats,
    get online() { return stats.online; },
    set onWord(fn) { onWord = fn; },
    set onStats(fn) { onStats = fn; },
  };
})();
