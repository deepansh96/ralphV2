#!/usr/bin/env node

import { createServer } from "node:http";
import { link, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const assetsDir = resolve(dirname(fileURLToPath(import.meta.url)), "../assets");
const args = parseArgs(process.argv.slice(2));
const sessionDir = resolve(args.session ?? "");
const host = "127.0.0.1";
const port = parsePort(args.port ?? "4173");
const markerPath = join(sessionDir, ".quiz-grilling-session");
const questionsPath = join(sessionDir, "questions.json");
const pidPath = join(sessionDir, "server.pid");
const readyPath = join(sessionDir, "server-ready.json");

await requireSession();
await requireNoLiveServer();

const assets = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]],
  ["/app.js", ["app.js", "text/javascript; charset=utf-8"]],
  ["/styles.css", ["styles.css", "text/css; charset=utf-8"]],
]);

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);

    if (request.method === "GET" && url.pathname === "/api/health") {
      return sendJson(response, 200, { ok: true });
    }

    if (request.method === "GET" && url.pathname === "/api/questions") {
      const questions = await loadQuestions();
      return sendJson(response, 200, questions, { "cache-control": "no-store" });
    }

    if (request.method === "POST" && url.pathname === "/api/submit") {
      const payload = await readJsonBody(request);
      const questions = await loadQuestions();
      const answers = validateAnswers(payload, questions);
      const outputPath = join(sessionDir, `answers-round-${questions.round}.json`);
      const tempPath = `${outputPath}.${process.pid}.tmp`;
      const output = {
        title: questions.title,
        round: questions.round,
        submittedAt: new Date().toISOString(),
        answers,
      };
      await writeFile(tempPath, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o600 });
      try {
        // link() is atomic and fails with EEXIST, so a round can never be overwritten once submitted.
        await link(tempPath, outputPath);
      } catch (error) {
        if (error.code === "EEXIST") {
          const conflict = new Error(`Round ${questions.round} already has submitted answers`);
          conflict.statusCode = 409;
          throw conflict;
        }
        throw error;
      } finally {
        await rm(tempPath, { force: true });
      }
      return sendJson(response, 201, { ok: true, file: `answers-round-${questions.round}.json` });
    }

    if (request.method === "GET" && assets.has(url.pathname)) {
      const [filename, contentType] = assets.get(url.pathname);
      const body = await readFile(join(assetsDir, filename));
      return send(response, 200, body, contentType);
    }

    sendJson(response, 404, { error: "Not found" });
  } catch (error) {
    const statusCode = error.statusCode ?? 500;
    const message = statusCode === 500 ? "Internal server error" : error.message;
    sendJson(response, statusCode, { error: message });
    if (statusCode === 500) console.error(error);
  }
});

server.on("clientError", (_error, socket) => socket.end("HTTP/1.1 400 Bad Request\r\n\r\n"));

await new Promise((resolveListen, rejectListen) => {
  server.once("error", rejectListen);
  server.listen(port, host, resolveListen);
});

const address = server.address();
const actualPort = typeof address === "object" && address ? address.port : port;
const localUrl = `http://${host}:${actualPort}`;
await writeFile(pidPath, `${process.pid}\n`, { mode: 0o600 });
await writeAtomic(readyPath, { pid: process.pid, url: localUrl });
console.log(JSON.stringify({ event: "ready", pid: process.pid, url: localUrl }));

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close(async () => {
      await Promise.allSettled([rm(pidPath, { force: true }), rm(readyPath, { force: true })]);
      process.exit(0);
    });
  });
}

function parseArgs(values) {
  const parsed = {};
  for (let index = 0; index < values.length; index += 2) {
    const key = values[index];
    const value = values[index + 1];
    if (!key?.startsWith("--") || value === undefined) usage();
    const name = key.slice(2);
    if (!new Set(["session", "port"]).has(name)) usage();
    parsed[name] = value;
  }
  if (!parsed.session) usage();
  return parsed;
}

function usage() {
  console.error("Usage: serve-quiz.mjs --session <dir> [--port 4173]");
  process.exit(2);
}

function parsePort(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) usage();
  return parsed;
}

async function requireSession() {
  let marker;
  try {
    marker = (await readFile(markerPath, "utf8")).trim();
  } catch {
    throw new Error(`Not a quiz-grilling session: ${sessionDir}`);
  }
  if (marker !== "quiz-grilling-v1") throw new Error(`Not a quiz-grilling session: ${sessionDir}`);
}

async function requireNoLiveServer() {
  let recordedPid;
  try {
    recordedPid = Number((await readFile(pidPath, "utf8")).trim());
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    await rm(readyPath, { force: true });
    return;
  }

  let alive = false;
  if (Number.isInteger(recordedPid) && recordedPid > 0) {
    try {
      process.kill(recordedPid, 0);
      alive = true;
    } catch (error) {
      alive = error.code !== "ESRCH";
    }
  }
  if (alive) throw new Error(`Quiz server PID ${recordedPid} is already running for this session`);
  await Promise.all([rm(pidPath, { force: true }), rm(readyPath, { force: true })]);
}

async function loadQuestions() {
  const document = JSON.parse(await readFile(questionsPath, "utf8"));
  validateQuestions(document);
  return document;
}

function validateQuestions(document) {
  if (!document || typeof document !== "object") badRequest("Questions must be an object");
  if (typeof document.title !== "string" || !document.title.trim()) badRequest("Quiz title is required");
  if (!Number.isInteger(document.round) || document.round < 1) badRequest("Round must be a positive integer");
  if (!Array.isArray(document.questions) || document.questions.length < 1 || document.questions.length > 100) {
    badRequest("Quiz must contain 1 to 100 questions");
  }

  const questionIds = new Set();
  for (const question of document.questions) {
    if (!question || typeof question !== "object") badRequest("Every question must be an object");
    for (const field of ["id", "title", "body", "recommendation"]) {
      if (typeof question[field] !== "string" || !question[field].trim()) badRequest(`Question ${field} is required`);
    }
    if (questionIds.has(question.id)) badRequest(`Duplicate question ID: ${question.id}`);
    questionIds.add(question.id);
    if (!question.waitWhat || ["context", "question", "recommendation"].some(
      (field) => typeof question.waitWhat[field] !== "string" || !question.waitWhat[field].trim(),
    )) {
      badRequest(`Question ${question.id} needs a complete waitWhat version`);
    }
    if (!Array.isArray(question.options) || question.options.length < 2) {
      badRequest(`Question ${question.id} needs at least two options`);
    }
    const optionIds = new Set();
    let recommended = 0;
    for (const option of question.options) {
      if (!option || typeof option !== "object" || typeof option.id !== "string" || !option.id.trim()
        || typeof option.label !== "string" || !option.label.trim()) {
        badRequest(`Question ${question.id} has an invalid option`);
      }
      if (optionIds.has(option.id)) badRequest(`Question ${question.id} has duplicate option ${option.id}`);
      optionIds.add(option.id);
      if (option.recommended === true) recommended += 1;
    }
    if (recommended !== 1) badRequest(`Question ${question.id} needs exactly one recommended option`);
  }
}

function validateAnswers(payload, questions) {
  if (!payload || payload.round !== questions.round || !Array.isArray(payload.answers)) {
    badRequest("Answers do not match the current round");
  }
  if (payload.answers.length !== questions.questions.length) badRequest("Every question must be answered");

  const submitted = new Map();
  for (const answer of payload.answers) {
    if (!answer?.questionId || submitted.has(answer.questionId)) badRequest("Answer IDs must be unique");
    submitted.set(answer.questionId, answer);
  }

  return questions.questions.map((question) => {
    const answer = submitted.get(question.id);
    if (!answer) badRequest(`Missing answer for ${question.id}`);
    const hasText = typeof answer.text === "string";
    const hasOption = typeof answer.optionId === "string";
    if (hasText && hasOption) badRequest(`Answer for ${question.id} must choose an option or text, not both`);
    if (hasText && answer.text.trim()) {
      return { questionId: question.id, text: answer.text.trim().slice(0, 10000) };
    }
    const validOption = question.options.some((option) => option.id === answer.optionId);
    if (!validOption) badRequest(`Invalid answer for ${question.id}`);
    return { questionId: question.id, optionId: answer.optionId };
  });
}

async function readJsonBody(request) {
  if (!(request.headers["content-type"] ?? "").startsWith("application/json")) {
    const error = new Error("Content-Type must be application/json");
    error.statusCode = 415;
    throw error;
  }

  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 1024 * 1024) {
      const error = new Error("Request body is too large");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    badRequest("Request body must be valid JSON");
  }
}

function badRequest(message) {
  const error = new Error(message);
  error.statusCode = 400;
  throw error;
}

async function writeAtomic(path, value) {
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

function sendJson(response, statusCode, value, headers = {}) {
  send(response, statusCode, `${JSON.stringify(value)}\n`, "application/json; charset=utf-8", headers);
}

function send(response, statusCode, body, contentType, headers = {}) {
  response.writeHead(statusCode, {
    "content-type": contentType,
    "content-security-policy": "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    ...headers,
  });
  response.end(body);
}
