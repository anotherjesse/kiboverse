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

  function setupKnowledgeProgress() {
    const progress = $("#knowledge-progress");
    if (!progress) return;
    const title = $("#knowledge-progress-title", progress);
    const detail = $("#knowledge-progress-detail", progress);
    const forms = document.querySelectorAll("form[data-knowledge-action]");
    for (const form of forms) {
      form.addEventListener("submit", (event) => {
        if (root.dataset.knowledgeBusy === "true") {
          event.preventDefault();
          return;
        }
        event.preventDefault();
        root.dataset.knowledgeBusy = "true";
        $(".knowledge-main")?.setAttribute("aria-busy", "true");
        if (title) title.textContent = form.dataset.progressTitle || "Updating knowledge";
        if (detail) detail.textContent = form.dataset.progressDetail || "This may take a moment.";
        progress.hidden = false;
        for (const button of document.querySelectorAll("form[data-knowledge-action] button")) {
          button.disabled = true;
        }
        for (const input of document.querySelectorAll("form[data-knowledge-action] input")) {
          input.readOnly = true;
        }
        const submitButton = form.querySelector("button[type=submit]");
        if (submitButton) submitButton.textContent = form.dataset.progressButton || "Working…";
        window.setTimeout(() => {
          if (root.dataset.knowledgeBusy === "true" && detail) {
            detail.textContent = form.dataset.progressLong || "Still working—larger sources can take a little longer.";
          }
        }, 8000);
        // Let the progress panel paint before native navigation begins.
        window.requestAnimationFrame(() => {
          window.requestAnimationFrame(() => form.submit());
        });
      });
    }
  }

  setupKnowledgeProgress();

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

  function startPlayback(player, retry = false, intent = playbackIntent) {
    pauseNativePlayback();
    return player.play(retry, intent);
  }

  function automaticPlaybackCurrent(player) {
    return (player.playing && player.ownsAutomaticIntent(playbackIntent)) ||
      (deferredPlayback?.player === player && deferredPlayback.retry &&
        deferredPlayback.intent === playbackIntent) ||
      (interruptedPlayback?.player === player &&
        interruptedPlayback.intent === playbackIntent &&
        player.ownsAutomaticIntent(playbackIntent));
  }

  function requestPlayback(player, retry = false) {
    if (retry && player.automaticPlaybackBlocked()) {
      return Promise.reject(player.automaticPlaybackError());
    }
    // The WebSocket event can beat the matching POST continuation. Treat both
    // as one automatic command before allocating a superseding global intent.
    if (retry && automaticPlaybackCurrent(player)) {
      return Promise.resolve();
    }
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
    return startPlayback(player, retry, intent);
  }

  function requestInitialPlayback(player) {
    if (!player.claimInitialAutomaticPlayback()) return null;
    return requestPlayback(player, true);
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

  function cancelAutomaticPlayback(player, error) {
    const matches = (request) => request?.player === player &&
      (request.retry || player.ownsAutomaticIntent(request.intent));
    let canceledCurrent = false;
    if (matches(deferredPlayback)) {
      canceledCurrent ||= deferredPlayback.intent === playbackIntent;
      deferredPlayback = null;
    }
    if (matches(interruptedPlayback)) {
      canceledCurrent ||= interruptedPlayback.intent === playbackIntent;
      interruptedPlayback = null;
    }
    canceledCurrent = player.cancelAutomaticPlayback(playbackIntent, error) || canceledCurrent;
    if (canceledCurrent && !player.playing) player.render("error");
    return canceledCurrent;
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
      startPlayback(request.player, request.retry, request.intent).catch(() => {});
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
    if (event.type === "pointerdown") recordButton?.setPointerCapture?.(event.pointerId);
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

  function isTextEntry(target) {
    if (!(target instanceof Element)) return false;
    if (target.isContentEditable) return true;
    const tag = target.tagName;
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
  }

  recordButton?.addEventListener("pointerdown", beginRecord);
  recordButton?.addEventListener("pointerup", endRecord);
  recordButton?.addEventListener("pointercancel", endRecord);
  recordButton?.addEventListener("lostpointercapture", endRecord);
  document.addEventListener("keydown", (event) => {
    if (event.code !== "Space" || event.ctrlKey || event.metaKey || event.altKey) return;
    if (isTextEntry(event.target)) return;
    beginRecord(event);
  });
  document.addEventListener("keyup", (event) => {
    if (event.code !== "Space" || !recordPressed) return;
    endRecord(event);
  });
  window.addEventListener("blur", endRecord);
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
      const playback = requestInitialPlayback(playerFor(turnId));
      if (playback) {
        setStatus(recordingStatus, "Reply incoming…", "working");
        playback.catch((error) => {
          setStatus(recordingStatus, `Speech unavailable: ${errorMessage(error)}`, "error");
        });
      }
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
      this.generation = null;
      this.announcedGeneration = null;
      this.session = null;
      this.automaticIntent = null;
      this.automaticTerminalError = null;
      this.initialAutomaticPlaybackClaimed = false;
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

    async play(retry = false, intent = playbackIntent) {
      if (this.session) return;
      if (retry && this.automaticTerminalError) throw this.automaticPlaybackError();
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
        intent,
        generationReset: false,
      };
      if (retry) {
        this.automaticIntent = intent;
      } else if (this.automaticIntent !== intent) {
        this.automaticIntent = null;
        this.announcedGeneration = null;
      }
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
        const headers = this.generation
          ? { "X-Speech-Generation": this.generation }
          : {};
        response = await fetch(`${endpoint("speech", this.turnId)}?from_sample=${fromSample}`, {
          headers,
          signal: session.controller.signal,
        });
        if (this.session !== session) return;
        if (response.ok) break;
        if (response.status === 412) {
          if (session.generationReset) {
            throw new Error("Speech generation changed more than once");
          }
          session.generationReset = true;
          this.position = 0;
          session.playedThrough = 0;
          this.generation = null;
          await this.streamFrom(0, session, retry);
          return;
        }
        if (attempt + 1 === attempts || ![404, 409, 425, 503].includes(response.status)) {
          throw new Error((await response.text()) || `Speech failed (${response.status})`);
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
      if (this.session !== session) return;
      const responseGeneration = response.headers.get("X-Speech-Generation") || "legacy";
      const expectedAnnouncement = this.automaticIntent === session.intent
        ? this.announcedGeneration
        : null;
      if ((this.generation && this.generation !== responseGeneration) ||
          (expectedAnnouncement && expectedAnnouncement !== responseGeneration)) {
        this.generation = null;
        throw new Error("Speech generation disagreed with its update");
      }
      this.generation = responseGeneration;
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

    restartForSpeechGeneration(generation, intent) {
      const announced = typeof generation === "string" && generation.length > 0
        ? generation
        : null;
      const changedAnnouncement = announced !== null && this.announcedGeneration !== null &&
        this.announcedGeneration !== announced;
      const changedTransport = announced !== null && this.generation !== null &&
        this.generation !== announced;
      if (announced) {
        this.announcedGeneration = announced;
        this.automaticTerminalError = null;
      }
      if (this.automaticIntent !== intent) return false;
      // The initial retrying request is already waiting for the first
      // generation. A later generation must replace an active old stream, and
      // a failed stream must restart when its successor begins.
      if (this.session && !changedAnnouncement && !changedTransport) return false;
      const session = this.session;
      this.position = 0;
      this.generation = null;
      this.session = null;
      if (activePlayer === this) activePlayer = null;
      if (session) this.stopSession(session);
      return true;
    }

    ownsAutomaticIntent(intent) {
      return this.automaticIntent === intent;
    }

    claimInitialAutomaticPlayback() {
      if (this.initialAutomaticPlaybackClaimed) return false;
      this.initialAutomaticPlaybackClaimed = true;
      return true;
    }

    automaticPlaybackBlocked() {
      return this.automaticTerminalError !== null;
    }

    automaticPlaybackError() {
      return new Error(this.automaticTerminalError || "Speech synthesis failed");
    }

    cancelAutomaticPlayback(currentIntent, error) {
      const session = this.session;
      const ownsSession = session !== null && this.ownsAutomaticIntent(session.intent);
      const ownedCurrentIntent = this.ownsAutomaticIntent(currentIntent);
      const position = ownsSession ? this.currentSample() : this.position;
      this.automaticTerminalError = error || "Speech synthesis failed";
      this.automaticIntent = null;
      this.announcedGeneration = null;
      if (!ownsSession) return ownedCurrentIntent;
      this.position = position;
      this.session = null;
      if (activePlayer === this) activePlayer = null;
      this.stopSession(session);
      this.render("error");
      return ownedCurrentIntent;
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
      const completedAutomaticPlayback = this.automaticIntent !== null;
      this.position = Math.max(this.position, session.playedThrough);
      this.session = null;
      this.automaticIntent = null;
      this.announcedGeneration = null;
      if (activePlayer === this) activePlayer = null;
      this.render("ended");
      if (completedAutomaticPlayback) {
        setStatus(recordingStatus, "Reply played", "success");
      }
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
        const canceledAutomatic = automaticPlaybackCurrent(this);
        cancelPlaybackIntent();
        if (this.playing) this.pause();
        else this.render("paused");
        if (canceledAutomatic) {
          setStatus(recordingStatus, "Reply playback canceled", "");
        }
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

  // Both a recording and a reply are click-to-play: the whole bubble is the
  // toggle, with no separate controls. A recording drives a plain hidden
  // <audio>; a reply drives its streaming PcmPlayer and restarts from the top
  // on each fresh click (replay). The global capture-phase "play" handler and
  // PcmPlayer both pause anything else, so only one thing plays at a time.
  function finishingSelection(bubble) {
    const selection = window.getSelection?.();
    return !!selection && !selection.isCollapsed && bubble.contains(selection.anchorNode);
  }

  function toggleClip(bubble) {
    const audio = bubble.querySelector("audio");
    if (!audio) return;
    if (audio.paused) audio.play().catch(() => {});
    else audio.pause();
  }

  function toggleReply(bubble) {
    const turnId = bubble.dataset.turnId;
    if (!turnId) return;
    const player = playerFor(turnId);
    if (player.playing || playbackPendingFor(player)) player.toggle();
    else player.restart();
  }

  document.addEventListener("click", (event) => {
    const clip = event.target.closest("[data-clip]");
    if (clip) {
      if (!finishingSelection(clip)) toggleClip(clip);
      return;
    }
    const reply = event.target.closest("[data-speech-player]");
    if (reply && !finishingSelection(reply)) toggleReply(reply);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Enter") return;
    const clip = event.target.closest?.("[data-clip]");
    if (clip) { event.preventDefault(); toggleClip(clip); return; }
    const reply = event.target.closest?.("[data-speech-player]");
    if (reply) { event.preventDefault(); toggleReply(reply); }
  });

  // Timeline forms are re-rendered on every refresh, so retries are handled
  // by delegation: post in place and let the journal broadcast refresh the
  // fragment with the reopened state.
  document.addEventListener("submit", (event) => {
    const form = event.target.closest?.("form[data-timeline-retry]");
    if (!form) return;
    event.preventDefault();
    if (form.dataset.submitting === "true") return;
    form.dataset.submitting = "true";
    const button = form.querySelector("button");
    if (button) button.disabled = true;
    fetch(form.action, { method: "POST" })
      .then((response) => {
        if (!response.ok) throw new Error(`retry failed: ${response.status}`);
        // Success: the journal broadcast refreshes the fragment, which
        // replaces this form wholesale.
      })
      .catch((error) => {
        console.warn("retry request failed", error);
      })
      .finally(() => {
        if (form.isConnected) {
          delete form.dataset.submitting;
          if (button) button.disabled = false;
        }
      });
  });

  for (const type of ["play", "playing", "pause", "ended"]) {
    document.addEventListener(type, (event) => {
      if (!(event.target instanceof HTMLAudioElement)) return;
      const bubble = event.target.closest("[data-clip]");
      if (!bubble) return;
      const playing = (type === "play" || type === "playing") && !event.target.paused;
      bubble.dataset.state = playing ? "playing" : "paused";
      bubble.setAttribute("aria-label", playing ? "Pause recording" : "Play recording");
    }, true);
  }

  function scheduleTimelineRefresh() {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(refreshTimeline, 80);
  }

  function followReplyPlayback(event) {
    const turnId = event.turn;
    if (!turnId) return;
    if (event.kind === "speech_started") {
      const player = playerFor(turnId);
      if (!player.restartForSpeechGeneration(event.generation, playbackIntent)) return;
      setStatus(recordingStatus, "Retrying speech…", "working");
      requestPlayback(player, true).catch((error) => {
        setStatus(recordingStatus, `Reply ready — press play (${errorMessage(error)})`, "error");
      });
      return;
    }
    if (event.kind === "tts_error" && event.terminal === true) {
      const player = playerFor(turnId);
      if (cancelAutomaticPlayback(player, event.error)) {
        setStatus(
          recordingStatus,
          `Speech unavailable: ${event.error || "Speech synthesis failed"}`,
          "error",
        );
      }
      return;
    }
    if (event.kind !== "reply") return;
    const hasAudio = typeof event.audio === "string" && event.audio.length > 0;
    if (!hasAudio) return;
    const player = playerFor(turnId);
    if (player.playing) return;
    if (navigator.userActivation && !navigator.userActivation.hasBeenActive) {
      setStatus(recordingStatus, "Reply ready — press play", "success");
      return;
    }
    // play() is intentionally idempotent while active, so the local POST path
    // and a matching event never create two streams.
    const playback = requestInitialPlayback(player);
    if (!playback) return;
    setStatus(recordingStatus, "Reply incoming…", "working");
    playback.catch((error) => {
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
        followReplyPlayback(event);
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
