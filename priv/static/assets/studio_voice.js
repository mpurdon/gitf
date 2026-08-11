// Planning-studio voice client: mic → Phoenix Channel → provider, and back.
// Loaded by the StudioVoice LiveView hook (see layouts.ex). Exposes
// window.GitfStudioVoice = { start(sessionId, callbacks), stop() }.
//
// Capture: getUserMedia → AudioWorklet downsampling to 16kHz PCM16 mono.
// Playback: 24kHz PCM16 chunks queued through an AudioContext; barge-in
// ("interrupted" event) flushes the queue.
(function () {
  const CAPTURE_RATE = 16000;
  const PLAYBACK_RATE = 24000;

  const workletSource = `
    class GitfDownsampler extends AudioWorkletProcessor {
      constructor() {
        super();
        this._acc = [];
        this._ratio = sampleRate / ${CAPTURE_RATE};
        this._pos = 0;
      }
      process(inputs) {
        const input = inputs[0];
        if (!input || !input[0]) return true;
        const ch = input[0];
        // Linear-interpolation downsample to 16kHz.
        const out = [];
        while (this._pos < ch.length - 1) {
          const i = Math.floor(this._pos);
          const frac = this._pos - i;
          out.push(ch[i] * (1 - frac) + ch[i + 1] * frac);
          this._pos += this._ratio;
        }
        this._pos -= ch.length;
        if (out.length) {
          const pcm = new Int16Array(out.length);
          for (let i = 0; i < out.length; i++) {
            const s = Math.max(-1, Math.min(1, out[i]));
            pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
          }
          this.port.postMessage(pcm.buffer, [pcm.buffer]);
        }
        return true;
      }
    }
    registerProcessor("gitf-downsampler", GitfDownsampler);
  `;

  let state = null;

  function b64FromBuffer(buf) {
    let binary = "";
    const bytes = new Uint8Array(buf);
    for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  function bufferFromB64(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }

  async function start(sessionId, callbacks) {
    if (state) await stop();
    callbacks = callbacks || {};

    const socket = new window.Phoenix.Socket("/socket");
    socket.connect();
    const channel = socket.channel("studio_voice:" + sessionId, {});

    // Playback pipeline (24kHz).
    const playCtx = new AudioContext({ sampleRate: PLAYBACK_RATE });
    let playhead = 0;
    const sources = new Set();

    function playChunk(buf) {
      const pcm = new Int16Array(buf);
      const audio = playCtx.createBuffer(1, pcm.length, PLAYBACK_RATE);
      const chData = audio.getChannelData(0);
      for (let i = 0; i < pcm.length; i++) chData[i] = pcm[i] / 0x8000;
      const src = playCtx.createBufferSource();
      src.buffer = audio;
      src.connect(playCtx.destination);
      const at = Math.max(playCtx.currentTime, playhead);
      src.start(at);
      playhead = at + audio.duration;
      sources.add(src);
      src.onended = () => sources.delete(src);
    }

    function flushPlayback() {
      sources.forEach((s) => {
        try { s.stop(); } catch (_e) {}
      });
      sources.clear();
      playhead = 0;
    }

    channel.on("audio", ({ data }) => playChunk(bufferFromB64(data)));
    channel.on("interrupted", () => { flushPlayback(); if (callbacks.onInterrupted) callbacks.onInterrupted(); });
    channel.on("transcript", (msg) => { if (callbacks.onTranscript) callbacks.onTranscript(msg); });
    channel.on("voice_error", (msg) => { if (callbacks.onError) callbacks.onError(msg); });
    channel.on("ready", () => { if (callbacks.onReady) callbacks.onReady(); });

    await new Promise((resolve, reject) => {
      channel.join().receive("ok", resolve).receive("error", (e) => reject(new Error(e.reason || "join failed")));
    });

    // Capture pipeline.
    const media = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 },
    });
    const capCtx = new AudioContext();
    const blob = new Blob([workletSource], { type: "application/javascript" });
    await capCtx.audioWorklet.addModule(URL.createObjectURL(blob));
    const source = capCtx.createMediaStreamSource(media);
    const worklet = new AudioWorkletNode(capCtx, "gitf-downsampler");
    worklet.port.onmessage = (e) => channel.push("audio", { data: b64FromBuffer(e.data) });
    source.connect(worklet);

    state = { socket, channel, media, capCtx, playCtx, flushPlayback };
    return true;
  }

  async function stop() {
    if (!state) return;
    const s = state;
    state = null;
    try { s.flushPlayback(); } catch (_e) {}
    try { s.media.getTracks().forEach((t) => t.stop()); } catch (_e) {}
    try { await s.capCtx.close(); } catch (_e) {}
    try { await s.playCtx.close(); } catch (_e) {}
    try { s.channel.leave(); } catch (_e) {}
    try { s.socket.disconnect(); } catch (_e) {}
  }

  window.GitfStudioVoice = { start, stop };
})();
