(() => {
  "use strict";

  const root = document.body;
  const queryUrl = root?.dataset.queryUrl;
  const form = document.querySelector("#knowledge-query-form");
  const input = document.querySelector("#knowledge-query-input");
  const submitButton = document.querySelector("#knowledge-query-submit");
  const cancelButton = document.querySelector("#knowledge-query-cancel");
  const newButton = document.querySelector("#knowledge-query-new");
  const timeline = document.querySelector("#knowledge-query-timeline");
  const status = document.querySelector("#knowledge-query-status");
  const emptyState = document.querySelector("#knowledge-query-empty");

  if (!queryUrl || !form || !input || !submitButton || !cancelButton ||
      !newButton || !timeline || !status || !emptyState) {
    return;
  }

  const emptyTemplate = emptyState.cloneNode(true);
  const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)");
  let threadId = "";
  let controller = null;
  let requestVersion = 0;
  let busy = false;

  function setStatus(message, state = "") {
    status.textContent = message;
    status.dataset.state = state;
  }

  function setBusy(nextBusy) {
    busy = nextBusy;
    form.setAttribute("aria-busy", String(nextBusy));
    input.readOnly = nextBusy;
    submitButton.disabled = nextBusy;
    cancelButton.hidden = !nextBusy;
    cancelButton.disabled = !nextBusy;
    newButton.disabled = nextBusy;
  }

  function scrollToLatest() {
    window.requestAnimationFrame(() => {
      timeline.lastElementChild?.scrollIntoView({
        block: "nearest",
        behavior: reducedMotion?.matches ? "auto" : "smooth",
      });
    });
  }

  function makeMessage(role, label) {
    const message = document.createElement("article");
    message.className = "knowledge-query-message " + role;
    message.setAttribute("aria-label", label);
    const body = document.createElement("div");
    body.className = "knowledge-query-message-body";
    message.append(body);
    return { message, body };
  }

  function appendQuestion(question) {
    timeline.querySelector("#knowledge-query-empty")?.remove();
    const { message, body } = makeMessage("user", "Your question");
    const text = document.createElement("p");
    text.textContent = question;
    body.append(text);
    timeline.append(message);
    newButton.hidden = false;
    scrollToLatest();
  }

  function createTurn() {
    return {
      activities: new Map(),
      activityList: null,
      answer: null,
      answerBody: null,
      answerText: null,
      receivedText: false,
      finished: false,
    };
  }

  function ensureActivityList(turn) {
    if (turn.activityList) return turn.activityList;
    const panel = document.createElement("section");
    panel.className = "knowledge-query-activity";
    panel.setAttribute("aria-label", "Research activity");
    const heading = document.createElement("p");
    heading.className = "knowledge-query-activity-heading";
    heading.textContent = "Research trail";
    const list = document.createElement("ul");
    panel.append(heading, list);
    if (turn.answer) timeline.insertBefore(panel, turn.answer);
    else timeline.append(panel);
    turn.activityList = list;
    scrollToLatest();
    return list;
  }

  function activityState(value) {
    const statusName = typeof value === "string" ? value.toLowerCase() : "";
    if (statusName.includes("complete") || statusName === "done" || statusName === "success") {
      return "completed";
    }
    if (statusName.includes("error") || statusName.includes("fail")) return "error";
    if (statusName.includes("cancel") || statusName.includes("stop")) return "stopped";
    return "running";
  }

  function activityStateLabel(state) {
    if (state === "completed") return "Complete";
    if (state === "error") return "Failed";
    if (state === "stopped") return "Stopped";
    return "In progress";
  }

  function applyActivity(turn, event) {
    const list = ensureActivityList(turn);
    const id = typeof event.id === "string" && event.id
      ? event.id
      : "activity-" + (turn.activities.size + 1);
    let item = turn.activities.get(id);
    if (!item) {
      const row = document.createElement("li");
      const indicator = document.createElement("span");
      indicator.className = "query-activity-indicator";
      indicator.setAttribute("aria-hidden", "true");
      const label = document.createElement("span");
      label.className = "query-activity-label";
      const stateLabel = document.createElement("span");
      stateLabel.className = "query-activity-state";
      row.append(indicator, label, stateLabel);
      list.append(row);
      item = { row, label, stateLabel };
      turn.activities.set(id, item);
    }
    const state = activityState(event.status);
    item.row.dataset.status = state;
    item.label.textContent = typeof event.label === "string" && event.label
      ? event.label
      : "Reviewing the knowledge base";
    item.stateLabel.textContent = activityStateLabel(state);
    scrollToLatest();
  }

  function ensureAnswer(turn) {
    if (turn.answer) return;
    const { message, body } = makeMessage("assistant is-streaming", "Knowledge answer");
    const text = document.createTextNode("");
    body.append(text);
    timeline.append(message);
    turn.answer = message;
    turn.answerBody = body;
    turn.answerText = text;
    scrollToLatest();
  }

  function applyDelta(turn, event) {
    if (typeof event.text !== "string" || !event.text) return;
    ensureAnswer(turn);
    turn.answerText.appendData(event.text);
    turn.receivedText = true;
    scrollToLatest();
  }

  function completeActivities(turn) {
    for (const item of turn.activities.values()) {
      if (item.row.dataset.status !== "running") continue;
      item.row.dataset.status = "completed";
      item.stateLabel.textContent = activityStateLabel("completed");
    }
  }

  function applyCompleted(turn, event) {
    ensureAnswer(turn);
    turn.answer.classList.remove("is-streaming");
    turn.answerBody.className = "knowledge-query-message-body markdown-body query-answer-body";

    // The query API renders and sanitizes this final HTML. Streaming text above
    // is always appended through a Text node while the answer is in flight.
    if (typeof event.html === "string" && event.html) {
      turn.answerBody.innerHTML = event.html;
      for (const link of turn.answerBody.querySelectorAll("a[href]")) {
        link.target = "_blank";
        link.rel = "noopener noreferrer";
      }
    } else {
      turn.answerBody.textContent = typeof event.markdown === "string"
        ? event.markdown
        : turn.answerText.data;
    }
    completeActivities(turn);
    turn.finished = true;
    setStatus("Answer ready. Ask a follow-up or start a new conversation.", "success");
    scrollToLatest();
  }

  function applyError(turn, message) {
    if (turn.finished) return;
    // A failed turn is not safe to resume: the server revokes the opaque
    // continuation token whenever a stream does not reach `completed`.
    threadId = "";
    ensureAnswer(turn);
    turn.answer.classList.remove("is-streaming");
    turn.answer.classList.add("has-error");
    turn.answerBody.className = "knowledge-query-message-body query-error";
    turn.answerBody.textContent = message || "The agent could not finish this question.";
    turn.finished = true;
    setStatus("The question could not be completed. You can try again.", "error");
    scrollToLatest();
  }

  function applyStopped(turn) {
    if (turn.finished) return;
    threadId = "";
    ensureAnswer(turn);
    turn.answer.classList.remove("is-streaming");
    turn.answer.classList.add("is-stopped");
    if (!turn.receivedText) {
      turn.answerBody.textContent = "This question was stopped before an answer was ready.";
    } else {
      const note = document.createElement("span");
      note.className = "query-stopped-note";
      note.textContent = "Stopped";
      turn.answerBody.append(note);
    }
    for (const item of turn.activities.values()) {
      if (item.row.dataset.status !== "running") continue;
      item.row.dataset.status = "stopped";
      item.stateLabel.textContent = activityStateLabel("stopped");
    }
    turn.finished = true;
    setStatus("Stopped. You can revise the question or ask another.", "stopped");
    scrollToLatest();
  }

  function applyEvent(turn, event) {
    if (!event || typeof event !== "object") return;
    if (event.type === "started") {
      if (typeof event.query_id === "string" && event.query_id) {
        threadId = event.query_id;
      }
      setStatus("Investigating your knowledge…", "working");
      return;
    }
    if (event.type === "activity") {
      applyActivity(turn, event);
      return;
    }
    if (event.type === "delta") {
      applyDelta(turn, event);
      return;
    }
    if (event.type === "completed") {
      applyCompleted(turn, event);
      return;
    }
    if (event.type === "error") {
      applyError(
        turn,
        typeof event.message === "string" ? event.message : "The agent could not finish this question.",
      );
    }
  }

  async function readEvents(response, turn, version) {
    if (!response.body) throw new Error("The browser could not read the answer stream.");
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    const applyLine = (line) => {
      const trimmed = line.trim();
      if (!trimmed || version !== requestVersion) return;
      let event;
      try {
        event = JSON.parse(trimmed);
      } catch {
        throw new Error("The answer stream was interrupted.");
      }
      applyEvent(turn, event);
    };

    while (true) {
      const { value, done } = await reader.read();
      if (version !== requestVersion) {
        await reader.cancel().catch(() => {});
        return;
      }
      buffer += decoder.decode(value || new Uint8Array(), { stream: !done });
      const lines = buffer.split(/\r?\n/);
      buffer = lines.pop() || "";
      for (const line of lines) applyLine(line);
      if (done) break;
    }
    if (buffer.trim()) applyLine(buffer);
  }

  async function ask(question) {
    if (busy) return;
    const normalized = question.trim();
    if (!normalized) {
      input.focus();
      return;
    }

    const version = ++requestVersion;
    const turn = createTurn();
    const payload = { question: normalized };
    if (threadId) payload.thread_id = threadId;
    appendQuestion(normalized);
    input.value = "";
    setBusy(true);
    setStatus("Starting a careful read…", "working");
    controller = new AbortController();

    try {
      const response = await fetch(queryUrl, {
        method: "POST",
        headers: {
          "Accept": "application/x-ndjson",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      if (!response.ok) {
        throw new Error("The question could not be started (" + response.status + ").");
      }
      await readEvents(response, turn, version);
      if (version === requestVersion && !turn.finished) {
        applyError(turn, "The answer stream ended before the agent finished.");
      }
    } catch (error) {
      if (version !== requestVersion) return;
      if (error?.name === "AbortError") {
        applyStopped(turn);
        input.value = normalized;
      } else {
        applyError(turn, error instanceof Error ? error.message : "The question could not be completed.");
      }
    } finally {
      if (version !== requestVersion) return;
      controller = null;
      setBusy(false);
      input.focus();
    }
  }

  function stopCurrent() {
    if (!busy || !controller) return;
    threadId = "";
    cancelButton.disabled = true;
    setStatus("Stopping after the current step…", "working");
    controller.abort();
  }

  function resetConversation() {
    requestVersion += 1;
    controller?.abort();
    controller = null;
    threadId = "";
    setBusy(false);
    timeline.replaceChildren(emptyTemplate.cloneNode(true));
    newButton.hidden = true;
    input.value = "";
    setStatus("Ready for a question.");
    input.focus();
  }

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void ask(input.value);
  });

  input.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && busy) {
      event.preventDefault();
      stopCurrent();
      return;
    }
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      form.requestSubmit();
    }
  });

  timeline.addEventListener("click", (event) => {
    const suggestion = event.target.closest?.("[data-query-suggestion]");
    if (!suggestion || busy) return;
    input.value = suggestion.dataset.querySuggestion || "";
    input.focus();
  });

  cancelButton.addEventListener("click", stopCurrent);
  newButton.addEventListener("click", resetConversation);
  window.addEventListener("pagehide", () => controller?.abort());
})();
