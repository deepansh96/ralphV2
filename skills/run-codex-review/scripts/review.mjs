#!/usr/bin/env node

import { spawn } from "node:child_process";
import { realpathSync, statSync } from "node:fs";
import readline from "node:readline";

function usage() {
  console.log(`Usage:
  review.mjs [--cwd PATH] --uncommitted
  review.mjs [--cwd PATH] --base BRANCH
  review.mjs [--cwd PATH] --commit SHA
  review.mjs [--cwd PATH] --custom INSTRUCTIONS

Options:
  --timeout SECONDS  Stop a hung review after this many seconds (default: 1800)
  -h, --help         Show this help`);
}

function parseArgs(argv) {
  const options = { cwd: process.cwd(), timeoutMs: 1_800_000 };
  const targets = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      const next = argv[++i];
      if (!next) throw new Error(`${arg} requires a value`);
      return next;
    };

    switch (arg) {
      case "--cwd":
        options.cwd = value();
        break;
      case "--uncommitted":
        targets.push({ type: "uncommittedChanges" });
        break;
      case "--base":
        targets.push({ type: "baseBranch", branch: value() });
        break;
      case "--commit":
        targets.push({ type: "commit", sha: value() });
        break;
      case "--custom":
        targets.push({ type: "custom", instructions: value() });
        break;
      case "--timeout": {
        const seconds = Number(value());
        if (!Number.isFinite(seconds) || seconds <= 0) {
          throw new Error("--timeout must be a positive number");
        }
        options.timeoutMs = seconds * 1000;
        break;
      }
      case "-h":
      case "--help":
        usage();
        process.exit(0);
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (targets.length !== 1) {
    throw new Error("Choose exactly one of --uncommitted, --base, --commit, or --custom");
  }

  options.cwd = realpathSync(options.cwd);
  if (!statSync(options.cwd).isDirectory()) {
    throw new Error(`Not a directory: ${options.cwd}`);
  }
  options.target = targets[0];
  return options;
}

function turnIdFrom(params) {
  return params?.turnId || params?.turn?.id || null;
}

function itemText(item) {
  if (!item || typeof item !== "object") return "";
  if (!["agentMessage", "assistantMessage"].includes(item.type)) return "";
  if (typeof item.text === "string") return item.text;
  if (typeof item.content === "string") return item.content;
  return "";
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const child = spawn(process.env.CODEX_BIN || "codex", ["app-server"], {
    cwd: options.cwd,
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });

  let nextId = 1;
  let stderr = "";
  let stopError = null;
  const pending = new Map();
  const completed = new Map();
  const deltas = new Map();

  const send = (message) => {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  };
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { reject, resolve });
    send({ id, method, params });
  });

  const lines = readline.createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }

    if (message.id != null && !message.method) {
      const waiter = pending.get(message.id);
      if (!waiter) return;
      pending.delete(message.id);
      if (message.error) {
        waiter.reject(new Error(message.error.message || JSON.stringify(message.error)));
      } else {
        waiter.resolve(message.result);
      }
      return;
    }

    if (message.id != null && message.method) {
      send({
        id: message.id,
        error: {
          code: -32601,
          message: "The isolated review runner does not handle interactive requests",
        },
      });
      return;
    }

    const turnId = turnIdFrom(message.params);
    if (message.method === "item/agentMessage/delta" && turnId) {
      deltas.set(turnId, `${deltas.get(turnId) || ""}${message.params.delta || ""}`);
    } else if (message.method === "item/completed" && turnId && !deltas.get(turnId)) {
      const text = itemText(message.params.item);
      if (text) deltas.set(turnId, text);
    } else if (message.method === "turn/completed" && turnId) {
      completed.set(turnId, message.params.turn);
    }
  });

  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(-20_000);
  });

  const exited = new Promise((_, reject) => {
    child.once("error", (error) => {
      stopError ||= error;
      reject(error);
    });
    child.once("exit", (code, signal) => {
      const error = new Error(
        `codex app-server exited before review completion (${signal || `code ${code}`})` +
          (stderr.trim() ? `\n${stderr.trim()}` : "")
      );
      stopError ||= error;
      for (const waiter of pending.values()) waiter.reject(error);
      pending.clear();
      reject(error);
    });
  });

  const waitForTurn = async (turnId) => {
    while (!completed.has(turnId)) {
      if (stopError) throw stopError;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    return completed.get(turnId);
  };

  const timeout = new Promise((_, reject) => {
    const timer = setTimeout(() => {
      const error = new Error(`Review timed out after ${options.timeoutMs / 1000} seconds`);
      stopError ||= error;
      reject(error);
    }, options.timeoutMs);
    timer.unref();
  });

  const review = async () => {
    await request("initialize", {
      clientInfo: { name: "run-codex-review-skill", version: "1.0.0" },
    });
    send({ method: "initialized", params: {} });

    const thread = await request("thread/start", {
      approvalPolicy: "never",
      cwd: options.cwd,
      sandbox: "read-only",
    });
    const threadId = thread?.thread?.id;
    if (!threadId) throw new Error("App Server did not return a thread ID");

    const result = await request("review/start", {
      delivery: "inline",
      target: options.target,
      threadId,
    });
    const turnId = result?.turn?.id;
    if (!turnId) throw new Error("App Server did not return a review turn ID");

    const turn = await waitForTurn(turnId);
    if (turn.status !== "completed") {
      throw new Error(turn.error?.message || `Review ended with status ${turn.status}`);
    }

    const text = (deltas.get(turnId) || turn.items?.map(itemText).filter(Boolean).join("\n") || "").trim();
    console.log(text || "Review completed without textual findings.");
  };

  try {
    await Promise.race([review(), timeout, exited]);
  } finally {
    lines.close();
    child.stdin.end();
    child.kill("SIGTERM");
  }
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
