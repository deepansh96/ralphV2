const state = {
  quiz: null,
  index: 0,
  answers: new Map(),
  waitWhat: new Set(),
  submitting: false,
};

const elements = {
  title: document.querySelector("#quiz-title"),
  round: document.querySelector("#round-label"),
  card: document.querySelector("#card"),
  progressBar: document.querySelector("#progress-bar"),
  progressLabel: document.querySelector("#progress-label"),
  previous: document.querySelector("#previous"),
  next: document.querySelector("#next"),
  submit: document.querySelector("#submit"),
  status: document.querySelector("#status"),
};

elements.previous.addEventListener("click", () => move(-1));
elements.next.addEventListener("click", () => move(1));
elements.submit.addEventListener("click", submit);

load();

async function load() {
  try {
    const response = await fetch("/api/questions", { cache: "no-store" });
    if (!response.ok) throw new Error("The quiz is not ready yet.");
    state.quiz = await response.json();
    elements.title.textContent = state.quiz.title;
    elements.round.textContent = `Round ${state.quiz.round}`;
    render();
  } catch (error) {
    elements.card.textContent = error.message;
  }
}

function render() {
  const questions = state.quiz.questions;
  const question = questions[state.index];
  const answer = state.answers.get(question.id);
  const simplified = state.waitWhat.has(question.id);
  elements.card.replaceChildren();

  const cardHeader = node("div", "card-header");
  const headingGroup = node("div");
  headingGroup.append(node("p", "question-number", `Question ${state.index + 1}`));
  headingGroup.append(node("h2", "question-title", question.title));
  cardHeader.append(headingGroup, waitWhatToggle(question, simplified));

  const copy = node("div", simplified ? "question-copy simplified" : "question-copy");
  if (simplified) {
    copy.append(node("p", "context", question.waitWhat.context));
    copy.append(node("p", "body", question.waitWhat.question));
  } else {
    copy.append(node("p", "body", question.body));
  }

  const recommendation = node("aside", "recommendation");
  recommendation.append(node("span", "recommendation-label", "Recommended"));
  recommendation.append(node("p", "", simplified ? question.waitWhat.recommendation : question.recommendation));

  const fieldset = document.createElement("fieldset");
  fieldset.className = "options";
  fieldset.append(node("legend", "sr-only", `Answer ${question.title}`));
  for (const option of question.options) fieldset.append(optionControl(question, option, answer));
  fieldset.append(customControl(question, answer));

  elements.card.append(cardHeader, copy, recommendation, fieldset);

  const answered = state.answers.size;
  elements.progressLabel.textContent = `${answered} of ${questions.length} answered`;
  elements.progressBar.style.width = `${(answered / questions.length) * 100}%`;
  elements.previous.disabled = state.index === 0 || state.submitting;
  elements.next.hidden = state.index === questions.length - 1;
  elements.next.disabled = state.index === questions.length - 1 || state.submitting;
  elements.submit.hidden = state.index !== questions.length - 1;
  elements.submit.disabled = answered !== questions.length || state.submitting;
}

function waitWhatToggle(question, simplified) {
  const label = node("label", "wait-toggle");
  const input = document.createElement("input");
  input.type = "checkbox";
  input.checked = simplified;
  input.addEventListener("change", () => {
    if (input.checked) state.waitWhat.add(question.id);
    else state.waitWhat.delete(question.id);
    render();
  });
  label.append(input, node("span", "", "Wait, what?"));
  return label;
}

function optionControl(question, option, answer) {
  const label = node("label", "option");
  const input = document.createElement("input");
  input.type = "radio";
  input.name = `answer-${question.id}`;
  input.value = option.id;
  input.checked = answer?.optionId === option.id;
  input.addEventListener("change", () => {
    state.answers.set(question.id, { optionId: option.id });
    render();
  });
  const copy = node("span", "option-copy");
  const title = node("span", "option-title", option.label);
  if (option.recommended) title.append(node("span", "pill", "Recommended"));
  copy.append(title);
  if (option.description) copy.append(node("span", "option-description", option.description));
  label.append(input, copy);
  return label;
}

function customControl(question, answer) {
  const wrapper = node("div", "option custom-option");
  const label = node("label", "custom-label");
  const radio = document.createElement("input");
  radio.type = "radio";
  radio.name = `answer-${question.id}`;
  radio.checked = typeof answer?.text === "string";
  label.append(radio, node("span", "option-title", "Write my own answer"));
  const textarea = document.createElement("textarea");
  textarea.rows = 4;
  textarea.maxLength = 10000;
  textarea.placeholder = "Type your answer here…";
  textarea.value = answer?.text ?? "";
  const save = () => {
    const text = textarea.value.trim();
    if (text) state.answers.set(question.id, { text });
    else state.answers.delete(question.id);
    radio.checked = Boolean(text);
    updateControls();
  };
  radio.addEventListener("change", () => {
    const text = textarea.value.trim();
    if (text) state.answers.set(question.id, { text });
    else state.answers.delete(question.id);
    updateControls();
    textarea.focus();
  });
  textarea.addEventListener("input", save);
  wrapper.append(label, textarea);
  return wrapper;
}

function updateControls() {
  const total = state.quiz.questions.length;
  elements.progressLabel.textContent = `${state.answers.size} of ${total} answered`;
  elements.progressBar.style.width = `${(state.answers.size / total) * 100}%`;
  elements.submit.disabled = state.answers.size !== total || state.submitting;
}

function move(offset) {
  state.index = Math.max(0, Math.min(state.quiz.questions.length - 1, state.index + offset));
  render();
  elements.card.focus({ preventScroll: true });
  window.scrollTo({ top: 0, behavior: "smooth" });
}

async function submit() {
  if (state.answers.size !== state.quiz.questions.length || state.submitting) return;
  state.submitting = true;
  elements.status.textContent = "Saving your answers…";
  render();

  const answers = state.quiz.questions.map((question) => ({
    questionId: question.id,
    ...state.answers.get(question.id),
  }));

  try {
    const response = await fetch("/api/submit", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ round: state.quiz.round, answers }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error ?? "Could not save answers.");
    elements.status.textContent = "Done. Your answers were saved. You can return to the chat.";
    elements.submit.textContent = "Submitted";
  } catch (error) {
    state.submitting = false;
    elements.status.textContent = error.message;
    render();
  }
}

function node(tag, className = "", text = "") {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text) element.textContent = text;
  return element;
}
