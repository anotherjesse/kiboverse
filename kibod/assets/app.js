(() => {
  "use strict";

  const root = document.body;
  if (!root) return;

  const $ = (selector, scope = document) => scope.querySelector(selector);
  const projectId = root.dataset.projectId;
  const conversationId = root.dataset.conversationId;
  const conversationUrl = root.dataset.conversationUrl ||
    (projectId && conversationId
      ? `/v1/projects/${encodeURIComponent(projectId)}/conversations/${encodeURIComponent(conversationId)}`
      : "");
  const timelineUrl = root.dataset.timelineUrl || `${location.pathname}/timeline`;
  const eventsUrl = root.dataset.eventsUrl || `${conversationUrl}/events`;
  const recordButton = $("#record-button");
  const turnButton = $("#turn-button");
  const discardButton = $("#discard-failed-button");
  const recordingStatus = $("#recording-status");
  const connectionStatus = $("#connection-status");

  if (!conversationUrl) return;

  let cursor = Number(root.dataset.lastSeq || 0);
  let preparedRecorder = null;
  let recorderPreparation = null;
  let recordSession = null;
  let recordPressed = false;
  let recordingAttempt = null;
  let refreshTimer = 0;
  let socket = null;
  let reconnectTimer = 0;
  let reconnectDelay = 500;
  let activePlayer = null;
  let playbackIntent = 0;
  let interruptedPlayback = null;
  let deferredPlayback = null;
  const recordingHolds = new Set();
  const players = new Map();
  const clipCommits = new Set();
  const turnCommandKey = `kibo:pending-turn:${conversationUrl}`;

  function setStatus(element, message, state = "") {
    if (!element) return;
    element.textContent = message;
    element.dataset.state = state;
  }

  function errorMessage(error) {
    return error instanceof Error ? error.message : String(error);
  }

  function uuid() {
    return crypto.randomUUID?.() || `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  }

  function endpoint(kind, id = "") {
    const encoded = encodeURIComponent(id);
    if (kind === "clips") return `${conversationUrl}/clips/${encoded}`;
    if (kind === "turns") return `${conversationUrl}/turns`;
    if (kind === "speech") return `${conversationUrl}/turns/${encoded}/speech`;
    return conversationUrl;
  }

  function unixSeconds(date = new Date()) {
    return Math.floor(date.getTime() / 1000);
  }

  function sha256Hex(buffer) {
    return crypto.subtle.digest("SHA-256", buffer).then((hash) =>
      [...new Uint8Array(hash)].map((byte) => byte.toString(16).padStart(2, "0")).join("")
    );
  }

  function wavFromFloat32(chunks, frameCount, sampleRate) {
    const buffer = new ArrayBuffer(44 + frameCount * 2);
    const view = new DataView(buffer);
    const text = (offset, value) => {
      for (let index = 0; index < value.length; index += 1) {
        view.setUint8(offset + index, value.charCodeAt(index));
      }
    };
    text(0, "RIFF");
    view.setUint32(4, 36 + frameCount * 2, true);
    text(8, "WAVE");
    text(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    text(36, "data");
    view.setUint32(40, frameCount * 2, true);

    let offset = 44;
    let peak = 0;
    for (const chunk of chunks) {
      for (let index = 0; index < chunk.length; index += 1) {
        const sample = Math.max(-1, Math.min(1, chunk[index]));
        peak = Math.max(peak, Math.abs(sample));
        view.setInt16(offset, sample < 0 ? sample * 32768 : sample * 32767, true);
        offset += 2;
      }
    }
    return { buffer, peakPct: Math.round(peak * 100) };
  }

  async function openSpool() {
    if (!("indexedDB" in window)) return null;
    return new Promise((resolve, reject) => {
      const request = indexedDB.open("kibo-upload-spool", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("clips", { keyPath: "key" });
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  async function spoolTransaction(mode, operation) {
    const database = await openSpool();
    if (!database) return null;
    return new Promise((resolve, reject) => {
      const transaction = database.transaction("clips", mode);
      const request = operation(transaction.objectStore("clips"));
      let result;
      request.onsuccess = () => { result = request.result; };
      request.onerror = () => reject(request.error);
      transaction.oncomplete = () => {
        database.close();
        resolve(result);
      };
      transaction.onerror = () => {
        database.close();
        reject(transaction.error || new Error("Local clip storage failed"));
      };
      transaction.onabort = () => {
        database.close();
        reject(transaction.error || new Error("Local clip storage was interrupted"));
      };
    });
  }

  const saveClip = async (clip) => {
    const result = await spoolTransaction("readwrite", (store) => store.put(clip));
    if (result === null) throw new Error("durable local storage is unavailable");
    return result;
  };
  const removeClip = (key) => spoolTransaction("readwrite", (store) => store.delete(key));
  const spooledClips = () => spoolTransaction("readonly", (store) => store.getAll());

  async function uploadClip(clip) {
    const response = await fetch(clip.url, {
      method: "PUT",
      headers: {
        "Content-Type": "audio/wav",
        "X-Duration-Ms": String(clip.durationMs),
        "X-Peak-Pct": String(clip.peakPct),
        "X-Recorded-At": String(clip.recordedAt),
        "X-Content-Sha256": clip.sha256,
      },
      body: clip.wav,
    });
    if (!response.ok) {
      const error = new Error((await response.text()) || `Upload failed (${response.status})`);
      error.retryable = ![400, 409, 413].includes(response.status);
      if (!error.retryable) {
        clip.terminalError = error.message;
        await saveClip(clip);
        if (discardButton) discardButton.hidden = false;
      }
      throw error;
    }
    await removeClip(clip.key).catch(() => {});
    scheduleTimelineRefresh();
  }

  async function retrySpooledClips() {
    const clips = await spooledClips().catch(() => []);
    for (const clip of clips || []) {
      if (clip.conversationUrl !== conversationUrl) continue;
      if (clip.terminalError) {
        if (discardButton) discardButton.hidden = false;
        setStatus(recordingStatus, `A recording needs attention: ${clip.terminalError}`, "error");
        return false;
      }
      try {
        await uploadClip(clip);
      } catch {
        return false;
      }
    }
    return true;
  }

  function recorderIsLive(recorder) {
    return recorder &&
      recorder.context.state !== "closed" &&
      recorder.stream.getTracks().some((track) => track.readyState === "live");
  }

  function disposeRecorder(recorder) {
    if (!recorder) return;
    recorder.processor.onaudioprocess = null;
    recorder.processor.disconnect();
    recorder.input.disconnect();
    recorder.silent.disconnect();
    recorder.stream.getTracks().forEach((track) => track.stop());
    if (recorder.context.state !== "closed") recorder.context.close().catch(() => {});
  }

  async function createRecorder() {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
    });
    const AudioContext = window.AudioContext || window.webkitAudioContext;
    const context = new AudioContext();
    const input = context.createMediaStreamSource(stream);
    const processor = context.createScriptProcessor(4096, 1, 1);
    const silent = context.createGain();
    silent.gain.value = 0;
    const recorder = {
      context,
      stream,
      input,
      processor,
      silent,
      preRoll: [],
      preRollFrames: 0,
    };
    const maxPreRollFrames = Math.round(context.sampleRate * 0.35);
    processor.onaudioprocess = (event) => {
      const chunk = new Float32Array(event.inputBuffer.getChannelData(0));
      recorder.preRoll.push(chunk);
      recorder.preRollFrames += chunk.length;
      while (recorder.preRollFrames > maxPreRollFrames && recorder.preRoll.length > 1) {
        recorder.preRollFrames -= recorder.preRoll.shift().length;
      }
      const session = recordSession;
      if (session?.recorder === recorder) {
        session.chunks.push(chunk);
        session.capturedFrames += chunk.length;
        session.frameCount += chunk.length;
      }
    };
    input.connect(processor);
    processor.connect(silent);
    silent.connect(context.destination);
    stream.getTracks().forEach((track) => track.addEventListener("ended", () => {
      if (preparedRecorder === recorder) preparedRecorder = null;
    }));
    return recorder;
  }

  async function prepareRecorder() {
    if (recorderIsLive(preparedRecorder)) return preparedRecorder;
    if (recorderPreparation) return recorderPreparation;
    if (preparedRecorder) {
      disposeRecorder(preparedRecorder);
      preparedRecorder = null;
    }
    recorderPreparation = createRecorder()
      .then((recorder) => {
        preparedRecorder = recorder;
        return recorder;
      })
      .finally(() => { recorderPreparation = null; });
    return recorderPreparation;
  }

  async function prewarmGrantedMicrophone() {
    if (!navigator.mediaDevices?.getUserMedia || !navigator.permissions?.query) return;
    try {
      const permission = await navigator.permissions.query({ name: "microphone" });
      if (permission.state !== "granted") return;
      const recorder = await prepareRecorder();
      recorder.context.resume().catch(() => {});
    } catch {
      // Permission discovery is only an optimization; pressing still initializes capture.
    }
  }

  function pauseNativePlayback(except = null) {
    let paused = false;
    for (const media of document.querySelectorAll("audio, video")) {
      if (media !== except && !media.paused) {
        media.pause();
        paused = true;
      }
    }
    return paused;
  }

  function playbackPendingFor(player) {
    return (deferredPlayback?.player === player && deferredPlayback.intent === playbackIntent) ||
      (interruptedPlayback?.player === player && interruptedPlayback.intent === playbackIntent);
  }

  function startPlayback(player, retry = false) {
    pauseNativePlayback();
    return player.play(retry);
  }

  function requestPlayback(player, retry = false) {
    const intent = ++playbackIntent;
    const superseded = new Set([deferredPlayback?.player, interruptedPlayback?.player]);
    interruptedPlayback = null;
    if (recordingHolds.size) {
      deferredPlayback = { player, retry, intent };
      for (const previous of superseded) {
        if (previous && previous !== player && !previous.playing) previous.render("paused");
      }
      player.render("queued");
      return Promise.resolve();
    }
    deferredPlayback = null;
    for (const previous of superseded) {
      if (previous && previous !== player && !previous.playing) previous.render("paused");
    }
    return startPlayback(player, retry);
  }

  function cancelPlaybackIntent() {
    const pending = new Set([deferredPlayback?.player, interruptedPlayback?.player]);
    playbackIntent += 1;
    interruptedPlayback = null;
    deferredPlayback = null;
    for (const player of pending) {
      if (player && !player.playing) player.render("paused");
    }
  }

  function acquireRecordingHold(attempt) {
    recordingHolds.add(attempt);
    if (recordingHolds.size !== 1) return;

    attempt.clearPreRoll = pauseNativePlayback();
    const player = activePlayer;
    if (player?.playing) {
      interruptedPlayback = { player, intent: playbackIntent, retry: false };
      attempt.clearPreRoll = true;
      player.pause();
    }
    if (attempt.clearPreRoll && preparedRecorder) {
      preparedRecorder.preRoll = [];
      preparedRecorder.preRollFrames = 0;
    }
  }

  function releaseRecordingHold(attempt) {
    if (!recordingHolds.delete(attempt) || recordingHolds.size) return;

    const deferred = deferredPlayback;
    const interrupted = interruptedPlayback;
    deferredPlayback = null;
    interruptedPlayback = null;
    const request = deferred?.intent === playbackIntent
      ? deferred
      : interrupted?.intent === playbackIntent
        ? interrupted
        : null;
    if (request) {
      startPlayback(request.player, request.retry).catch(() => {});
    }
  }

  document.addEventListener("play", (event) => {
    const media = event.target;
    if (!(media instanceof HTMLMediaElement)) return;
    if (recordingHolds.size) {
      media.pause();
      return;
    }
    cancelPlaybackIntent();
    if (activePlayer?.playing) activePlayer.pause();
    pauseNativePlayback(media);
  }, true);

  async function startRecording(attempt) {
    if (recordSession || !recordPressed) {
      releaseRecordingHold(attempt);
      return;
    }
    if (!navigator.mediaDevices?.getUserMedia) {
      setStatus(recordingStatus, "Microphone recording is not supported by this browser.", "error");
      recordPressed = false;
      if (recordingAttempt === attempt) recordingAttempt = null;
      releaseRecordingHold(attempt);
      return;
    }

    setStatus(recordingStatus, "Waiting for microphone…", "working");
    try {
      const recorder = await prepareRecorder();
      if (!recordPressed || attempt !== recordingAttempt || recordSession) {
        releaseRecordingHold(attempt);
        setStatus(recordingStatus, "Hold to talk", "");
        return;
      }
      if (attempt.clearPreRoll) {
        recorder.preRoll = [];
        recorder.preRollFrames = 0;
      }
      const preRoll = recorder.preRoll.slice();
      recordSession = {
        recorder,
        chunks: preRoll,
        capturedFrames: 0,
        frameCount: preRoll.reduce((total, chunk) => total + chunk.length, 0),
        attempt,
      };
      await recorder.context.resume();
      if (!recordPressed || attempt !== recordingAttempt) {
        recordSession = null;
        releaseRecordingHold(attempt);
        setStatus(recordingStatus, "Hold to talk", "");
        return;
      }
      recordSession.limitTimer = setTimeout(() => {
        if (!recordSession) return;
        recordPressed = false;
        recordingAttempt = null;
        const commit = stopRecording(attempt);
        clipCommits.add(commit);
        commit.finally(() => clipCommits.delete(commit));
      }, 120000);
      recordButton?.setAttribute("aria-pressed", "true");
      root.classList.add("is-recording");
      setStatus(recordingStatus, "Listening… release to send", "recording");
    } catch (error) {
      if (recordSession?.attempt === attempt) recordSession = null;
      recordPressed = false;
      if (recordingAttempt === attempt) recordingAttempt = null;
      releaseRecordingHold(attempt);
      setStatus(recordingStatus, `Microphone unavailable: ${errorMessage(error)}`, "error");
    }
  }

  async function stopRecording(attempt) {
    const session = recordSession?.attempt === attempt ? recordSession : null;
    if (session) recordSession = null;
    recordButton?.setAttribute("aria-pressed", "false");
    root.classList.remove("is-recording");
    if (!session) {
      releaseRecordingHold(attempt);
      return;
    }
    clearTimeout(session.limitTimer);

    const sampleRate = session.recorder.context.sampleRate;
    session.recorder.preRoll = [];
    session.recorder.preRollFrames = 0;
    const capturedDurationMs = Math.round(session.capturedFrames * 1000 / sampleRate);
    if (capturedDurationMs < 500) {
      releaseRecordingHold(attempt);
      setStatus(recordingStatus, "Too short — hold a little longer", "error");
      return;
    }

    setStatus(recordingStatus, "Saving recording…", "working");
    let clip = null;
    try {
      const durationMs = Math.round(session.frameCount * 1000 / sampleRate);
      const { buffer, peakPct } = wavFromFloat32(session.chunks, session.frameCount, sampleRate);
      const id = uuid();
      clip = {
        key: `${conversationUrl}:${id}`,
        conversationUrl,
        id,
        url: endpoint("clips", id),
        durationMs,
        peakPct,
        recordedAt: unixSeconds(),
        sha256: await sha256Hex(buffer),
        wav: new Blob([buffer], { type: "audio/wav" }),
      };
      await saveClip(clip);
      releaseRecordingHold(attempt);
      await uploadClip(clip);
      setStatus(recordingStatus, "Sent — hold to add another thought", "success");
      return true;
    } catch (error) {
      const saved = await spooledClips()
        .then((clips) => clip && (clips || []).some((item) => item.key === clip.key))
        .catch(() => false);
      setStatus(
        recordingStatus,
        saved
          ? `Saved locally; will retry (${errorMessage(error)})`
          : `Recording could not be stored: ${errorMessage(error)}`,
        "error",
      );
      return false;
    } finally {
      releaseRecordingHold(attempt);
    }
  }

  function beginRecord(event) {
    if (event.type === "keydown" && (event.repeat || event.code !== "Space")) return;
    if (event.type === "pointerdown" && event.button !== 0) return;
    if (recordPressed) return;
    event.preventDefault();
    recordPressed = true;
    const attempt = {};
    acquireRecordingHold(attempt);
    recordingAttempt = attempt;
    recordButton?.setPointerCapture?.(event.pointerId);
    preparedRecorder?.context.resume().catch(() => {});
    startRecording(attempt);
  }

  function endRecord(event) {
    if (event.type === "keyup" && event.code !== "Space") return;
    if (!recordPressed) return;
    event.preventDefault();
    recordPressed = false;
    const attempt = recordingAttempt;
    recordingAttempt = null;
    const commit = stopRecording(attempt);
    clipCommits.add(commit);
    commit.finally(() => clipCommits.delete(commit));
  }

  recordButton?.addEventListener("pointerdown", beginRecord);
  recordButton?.addEventListener("pointerup", endRecord);
  recordButton?.addEventListener("pointercancel", endRecord);
  recordButton?.addEventListener("lostpointercapture", endRecord);
  recordButton?.addEventListener("keydown", beginRecord);
  recordButton?.addEventListener("keyup", endRecord);
  prewarmGrantedMicrophone();
  window.addEventListener("pageshow", prewarmGrantedMicrophone);
  window.addEventListener("pagehide", () => {
    clearTimeout(recordSession?.limitTimer);
    recordSession = null;
    recordPressed = false;
    recordingAttempt = null;
    cancelPlaybackIntent();
    recordingHolds.clear();
    if (activePlayer?.playing) activePlayer.pause();
    pauseNativePlayback();
    recordButton?.setAttribute("aria-pressed", "false");
    root.classList.remove("is-recording");
    if (preparedRecorder) disposeRecorder(preparedRecorder);
    preparedRecorder = null;
  });

  async function submitTurn() {
    if (!turnButton || turnButton.disabled) return;
    let turnId;
    try { turnId = localStorage.getItem(turnCommandKey) || uuid(); }
    catch { turnId = uuid(); }
    turnButton.disabled = true;
    setStatus(recordingStatus, "Finishing recordings…", "working");
    try {
      const commits = await Promise.all([...clipCommits]);
      const spoolClear = await retrySpooledClips();
      if (commits.includes(false) || !spoolClear) {
        throw new Error("recordings are saved locally but not on the server yet");
      }
      try { localStorage.setItem(turnCommandKey, turnId); } catch {}
      setStatus(recordingStatus, "Thinking…", "working");
      const response = await fetch(endpoint("turns"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ turn_id: turnId }),
      });
      if (!response.ok) throw new Error((await response.text()) || `Turn failed (${response.status})`);
      try { localStorage.removeItem(turnCommandKey); } catch {}
      scheduleTimelineRefresh();
      setStatus(recordingStatus, "Reply incoming…", "working");
      requestPlayback(playerFor(turnId), true).catch((error) => {
        setStatus(recordingStatus, `Speech unavailable: ${errorMessage(error)}`, "error");
      });
    } catch (error) {
      setStatus(recordingStatus, `Could not start reply: ${errorMessage(error)}`, "error");
    } finally {
      turnButton.disabled = false;
    }
  }

  turnButton?.addEventListener("click", submitTurn);

  discardButton?.addEventListener("click", async () => {
    const clips = await spooledClips().catch(() => []);
    for (const clip of clips || []) {
      if (clip.conversationUrl === conversationUrl && clip.terminalError) {
        await removeClip(clip.key).catch(() => {});
      }
    }
    discardButton.hidden = true;
    setStatus(recordingStatus, "Failed recording discarded; hold to try again", "");
  });

  class PcmPlayer {
    constructor(turnId) {
      this.turnId = turnId;
      this.context = null;
      this.rate = 24000;
      this.position = 0;
      this.session = null;
    }

    get playing() {
      return this.session !== null;
    }

    controls() {
      return document.querySelectorAll(`[data-speech-player][data-turn-id="${CSS.escape(this.turnId)}"]`);
    }

    render(state = this.playing ? "playing" : "paused") {
      const seconds = this.currentSample() / this.rate;
      const pending = playbackPendingFor(this);
      for (const control of this.controls()) {
        control.dataset.state = state;
        const readout = $("[data-audio-position]", control);
        if (readout) readout.textContent = formatTime(seconds);
        const toggle = $("[data-audio-action='toggle']", control);
        if (toggle) {
          toggle.textContent = this.playing ? "Pause" : pending ? "Cancel play" : "Play";
          toggle.setAttribute(
            "aria-label",
            this.playing ? "Pause reply" : pending ? "Cancel queued reply" : "Play reply",
          );
        }
      }
    }

    currentSample() {
      const session = this.session;
      if (!this.context || !session) return this.position;
      const now = this.context.currentTime;
      let sample = session.playedThrough;
      for (const item of session.sources) {
        if (now < item.start) break;
        const elapsed = Math.min(item.length, Math.max(0, Math.floor((now - item.start) * this.rate)));
        sample = Math.max(sample, item.sample + elapsed);
      }
      return sample;
    }

    async play(retry = false) {
      if (this.session) return;
      if (activePlayer && activePlayer !== this) activePlayer.pause();
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      try {
        this.context ||= new AudioContext({ sampleRate: this.rate });
      } catch (error) {
        throw error;
      }
      const session = {
        controller: new AbortController(),
        sources: new Set(),
        playedThrough: this.position,
        nextStart: 0,
        streamOpen: true,
      };
      this.session = session;
      activePlayer = this;
      this.render("loading");
      try {
        await this.context.resume();
      } catch (error) {
        if (this.session === session) this.fail(session, error);
        throw error;
      }
      if (this.session !== session) return;
      session.nextStart = this.context.currentTime + 0.04;
      this.streamFrom(this.position, session, retry).catch((error) => {
        if (this.session !== session || error.name === "AbortError") return;
        this.fail(session, error);
      });
    }

    async streamFrom(fromSample, session, retry) {
      let response;
      const attempts = retry ? 20 : 1;
      for (let attempt = 0; attempt < attempts; attempt += 1) {
        if (this.session !== session) return;
        response = await fetch(`${endpoint("speech", this.turnId)}?from_sample=${fromSample}`, {
          signal: session.controller.signal,
        });
        if (this.session !== session) return;
        if (response.ok) break;
        if (attempt + 1 === attempts || ![404, 409, 425, 503].includes(response.status)) {
          throw new Error((await response.text()) || `Speech failed (${response.status})`);
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
      if (this.session !== session) return;
      this.rate = Number(response.headers.get("X-Audio-Sample-Rate") || response.headers.get("X-Sample-Rate") || 24000);
      const reader = response.body?.getReader();
      if (!reader) throw new Error("This browser cannot stream response audio");
      let leftover = null;
      let sample = fromSample;
      this.render("playing");
      while (true) {
        const { value, done } = await reader.read();
        if (this.session !== session) return;
        if (done) break;
        let bytes = value;
        if (leftover !== null) {
          const joined = new Uint8Array(bytes.length + 1);
          joined[0] = leftover;
          joined.set(bytes, 1);
          bytes = joined;
          leftover = null;
        }
        if (bytes.length % 2) {
          leftover = bytes[bytes.length - 1];
          bytes = bytes.subarray(0, bytes.length - 1);
        }
        if (!bytes.length) continue;
        const samples = new Float32Array(bytes.length / 2);
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        for (let index = 0; index < samples.length; index += 1) {
          samples[index] = view.getInt16(index * 2, true) / 32768;
        }
        this.schedule(samples, sample, session);
        sample += samples.length;
      }
      session.streamOpen = false;
      this.finishIfComplete(session);
    }

    schedule(samples, startSample, session) {
      if (this.session !== session) return;
      const buffer = this.context.createBuffer(1, samples.length, this.rate);
      buffer.copyToChannel(samples, 0);
      const source = this.context.createBufferSource();
      source.buffer = buffer;
      source.connect(this.context.destination);
      const start = Math.max(session.nextStart, this.context.currentTime + 0.025);
      const item = { source, start, sample: startSample, length: samples.length };
      session.sources.add(item);
      session.nextStart = start + samples.length / this.rate;
      source.onended = () => {
        session.sources.delete(item);
        try { source.disconnect(); } catch {}
        if (this.session !== session) return;
        session.playedThrough = Math.max(session.playedThrough, startSample + samples.length);
        this.position = session.playedThrough;
        this.finishIfComplete(session);
      };
      source.start(start);
    }

    stopSession(session) {
      session.controller.abort();
      for (const item of session.sources) {
        try { item.source.stop(); } catch {}
        try { item.source.disconnect(); } catch {}
      }
      session.sources.clear();
      session.streamOpen = false;
    }

    finishIfComplete(session) {
      if (this.session !== session) return;
      if (session.sources.size || session.streamOpen) {
        this.render(session.sources.size ? "playing" : "loading");
        return;
      }
      this.position = Math.max(this.position, session.playedThrough);
      this.session = null;
      if (activePlayer === this) activePlayer = null;
      this.render("ended");
    }

    fail(session, error) {
      if (this.session !== session) return;
      this.position = this.currentSample();
      this.session = null;
      if (activePlayer === this) activePlayer = null;
      this.stopSession(session);
      this.render("error");
      setStatus(recordingStatus, `Speech unavailable: ${errorMessage(error)}`, "error");
    }

    pause() {
      const session = this.session;
      if (!session) {
        if (activePlayer === this) activePlayer = null;
        this.render("paused");
        return;
      }
      this.position = this.currentSample();
      this.session = null;
      if (activePlayer === this) activePlayer = null;
      this.stopSession(session);
      this.render("paused");
    }

    toggle() {
      if (this.playing || playbackPendingFor(this)) {
        cancelPlaybackIntent();
        if (this.playing) this.pause();
        else this.render("paused");
        return;
      }
      requestPlayback(this).catch((error) => {
        setStatus(recordingStatus, `Speech unavailable: ${errorMessage(error)}`, "error");
      });
    }

    rewind(seconds = 10) {
      const position = this.currentSample();
      cancelPlaybackIntent();
      this.pause();
      this.position = Math.max(0, position - Math.round(seconds * this.rate));
      requestPlayback(this).catch((error) => {
        setStatus(recordingStatus, `Speech unavailable: ${errorMessage(error)}`, "error");
      });
    }

    restart() {
      cancelPlaybackIntent();
      this.pause();
      this.position = 0;
      requestPlayback(this).catch((error) => {
        setStatus(recordingStatus, `Speech unavailable: ${errorMessage(error)}`, "error");
      });
    }
  }

  function formatTime(seconds) {
    const whole = Math.max(0, Math.floor(seconds));
    return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
  }

  function playerFor(turnId) {
    if (!players.has(turnId)) players.set(turnId, new PcmPlayer(turnId));
    return players.get(turnId);
  }

  document.addEventListener("click", (event) => {
    const button = event.target.closest("[data-audio-action]");
    if (!button) return;
    const controls = button.closest("[data-speech-player]");
    const turnId = controls?.dataset.turnId;
    if (!turnId) return;
    const player = playerFor(turnId);
    if (button.dataset.audioAction === "toggle") player.toggle();
    if (button.dataset.audioAction === "rewind") player.rewind(Number(button.dataset.seconds || 10));
    if (button.dataset.audioAction === "restart") player.restart();
  });

  function scheduleTimelineRefresh() {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(refreshTimeline, 80);
  }

  function autoPlayReply(event) {
    if (event?.kind !== "reply") return;
    const turnId = event.turn;
    const text = typeof event.text === "string" ? event.text.trim() : "";
    const hasAudio = typeof event.audio === "string" && event.audio.length > 0;
    if (!turnId || !hasAudio || !text || text.startsWith("[")) return;
    const player = playerFor(turnId);
    if (player.playing) return;
    if (navigator.userActivation && !navigator.userActivation.hasBeenActive) {
      setStatus(recordingStatus, "Reply ready — press play", "success");
      return;
    }
    // play() is intentionally idempotent while active, so the local POST path
    // and a matching event never create two streams.
    requestPlayback(player, true).catch((error) => {
      setStatus(recordingStatus, `Reply ready — press play (${errorMessage(error)})`, "error");
    });
  }

  async function refreshTimeline() {
    try {
      if (window.htmx) {
        await window.htmx.ajax("GET", timelineUrl, { target: "#timeline", swap: "innerHTML" });
      } else {
        const response = await fetch(timelineUrl, { headers: { "HX-Request": "true" } });
        if (!response.ok) throw new Error(`Timeline failed (${response.status})`);
        const timeline = $("#timeline");
        if (timeline) timeline.innerHTML = await response.text();
      }
      for (const player of players.values()) player.render();
    } catch (error) {
      setStatus(connectionStatus, `Updates delayed: ${errorMessage(error)}`, "error");
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(refreshTimeline, 1000);
    }
  }

  function applyEvents(payload) {
    const events = Array.isArray(payload) ? payload : payload.events || [payload];
    let changed = false;
    for (const event of events) {
      const seq = Number(event?.seq || 0);
      if (seq > cursor) {
        cursor = seq;
        root.dataset.lastSeq = String(cursor);
        if (event?.kind === "conversation_renamed" && typeof event.name === "string") {
          const heading = $(".conversation-header h1");
          if (heading) heading.textContent = event.name;
          document.title = `${event.name} · Kibo`;
          for (const link of document.querySelectorAll("a[data-conversation-id]")) {
            if (link.dataset.projectId === projectId && link.dataset.conversationId === conversationId) {
              link.textContent = event.name;
            }
          }
        }
        autoPlayReply(event);
        changed = true;
      }
    }
    if (changed) scheduleTimelineRefresh();
  }

  function websocketUrl() {
    const configured = root.dataset.eventsWsUrl;
    const url = new URL(configured || eventsUrl, location.href);
    url.searchParams.set("after", String(cursor));
    return url.toString().replace(/^http/, "ws");
  }

  async function connectEvents() {
    clearTimeout(reconnectTimer);
    try {
      socket = new WebSocket(websocketUrl());
      socket.addEventListener("open", () => {
        reconnectDelay = 500;
        setStatus(connectionStatus, "Live", "connected");
      });
      socket.addEventListener("message", (message) => {
        try {
          const payload = JSON.parse(message.data);
          const events = Array.isArray(payload) ? payload : payload.events || [payload];
          const firstSeq = Math.min(...events.map((event) => Number(event?.seq || Infinity)));
          if (firstSeq > cursor + 1) socket.close();
          else applyEvents(payload);
        } catch {
          socket.close();
        }
      });
      socket.addEventListener("close", () => {
        setStatus(connectionStatus, "Reconnecting…", "working");
        reconnectTimer = setTimeout(connectEvents, reconnectDelay);
        reconnectDelay = Math.min(10000, reconnectDelay * 2);
      });
      socket.addEventListener("error", () => socket.close());
    } catch (error) {
      setStatus(connectionStatus, `Offline: ${errorMessage(error)}`, "error");
      reconnectTimer = setTimeout(connectEvents, reconnectDelay);
      reconnectDelay = Math.min(10000, reconnectDelay * 2);
    }
  }

  window.addEventListener("online", () => {
    retrySpooledClips();
    if (!socket || socket.readyState > WebSocket.OPEN) connectEvents();
  });
  window.addEventListener("beforeunload", () => socket?.close());
  retrySpooledClips();
  connectEvents();
  try {
    if (localStorage.getItem(turnCommandKey)) submitTurn();
  } catch {}
})();
