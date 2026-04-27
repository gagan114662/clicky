#!/usr/bin/env node
/**
 * Local Anthropic API proxy — routes Claude calls through the `claude` CLI
 * so the packaged Clicky app works with a Claude Code subscription.
 *
 * Endpoints mirrored:
 *   POST /v1/messages          → claude CLI subprocess (streaming SSE)
 *   POST /tts                  → ElevenLabs direct
 *   POST /transcribe-token     → AssemblyAI direct
 *   GET  /transcribe-token     → AssemblyAI direct
 */

const http = require("http");
const https = require("https");
const { spawn } = require("child_process");
const os = require("os");
const path = require("path");
const fs = require("fs");

const PORT = 57328; // avoid 8787 which may be in use

const ASSEMBLYAI_KEY = process.env.ASSEMBLYAI_API_KEY || "";
const ELEVENLABS_KEY = process.env.ELEVENLABS_API_KEY || "";
const ELEVENLABS_VOICE_ID = process.env.ELEVENLABS_VOICE_ID || "21m00Tcm4TlvDq8ikWAM";

function findClaude() {
  const candidates = [
    path.join(os.homedir(), ".local/bin/claude"),
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
  ];
  return candidates.find((p) => fs.existsSync(p)) || "claude";
}

function buildEnv() {
  const env = { ...process.env };
  env.PATH = [
    path.join(os.homedir(), ".local/bin"),
    "/usr/local/bin",
    "/opt/homebrew/bin",
    env.PATH || "/usr/bin:/bin",
  ].join(":");
  return env;
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => resolve(data));
  });
}

function httpsRequest(options, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, resolve);
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// /v1/messages — translate Anthropic API request → claude CLI → Anthropic SSE
// ---------------------------------------------------------------------------
async function handleMessages(req, res) {
  const body = await readBody(req);
  let payload;
  try {
    payload = JSON.parse(body);
  } catch {
    res.writeHead(400);
    res.end("Bad JSON");
    return;
  }

  const systemPrompt = payload.system || "";
  const messages = payload.messages || [];
  const modelName = payload.model || "claude-sonnet-4-6";
  const streaming = payload.stream !== false;

  // Build content blocks for the last user message
  const lastUserMsg = [...messages].reverse().find((m) => m.role === "user");
  let contentBlocks = [];
  if (lastUserMsg) {
    if (Array.isArray(lastUserMsg.content)) {
      contentBlocks = lastUserMsg.content;
    } else {
      contentBlocks = [{ type: "text", text: lastUserMsg.content }];
    }
  }

  // Prepend history as text
  const history = messages.slice(0, messages.lastIndexOf(lastUserMsg));
  if (history.length > 0) {
    const histText = history
      .map((m) => {
        const text =
          typeof m.content === "string"
            ? m.content
            : (m.content || [])
                .filter((b) => b.type === "text")
                .map((b) => b.text)
                .join("");
        return `${m.role === "user" ? "Human" : "Assistant"}: ${text}`;
      })
      .join("\n\n");
    contentBlocks = [
      { type: "text", text: `Previous conversation:\n${histText}\n\n` },
      ...contentBlocks,
    ];
  }

  const inputEvent = JSON.stringify({
    type: "user",
    message: { role: "user", content: contentBlocks },
  });

  const args = [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--model",
    modelName,
    "--tools",
    "",
    "--permission-mode",
    "bypassPermissions",
    "--no-session-persistence",
  ];
  if (systemPrompt) args.push("--system-prompt", systemPrompt);

  const claudePath = findClaude();
  console.log(`→ claude ${args.slice(0, 4).join(" ")} ... (model=${modelName})`);

  const proc = spawn(claudePath, args, { env: buildEnv() });
  proc.stdin.write(inputEvent + "\n");
  proc.stdin.end();

  if (streaming) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      "Access-Control-Allow-Origin": "*",
    });

    const msgId = `msg_local_${Date.now()}`;
    const emit = (obj) => res.write(`data: ${JSON.stringify(obj)}\n\n`);

    emit({
      type: "message_start",
      message: {
        id: msgId,
        type: "message",
        role: "assistant",
        content: [],
        model: modelName,
        stop_reason: null,
        usage: { input_tokens: 0, output_tokens: 0 },
      },
    });
    emit({
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    });

    let buf = "";
    proc.stdout.on("data", (chunk) => {
      buf += chunk.toString();
      const lines = buf.split("\n");
      buf = lines.pop();
      for (const line of lines) {
        const t = line.trim();
        if (!t) continue;
        try {
          const ev = JSON.parse(t);
          if (ev.type === "assistant" && ev.message?.content) {
            for (const block of ev.message.content) {
              if (block.type === "text" && block.text) {
                emit({
                  type: "content_block_delta",
                  index: 0,
                  delta: { type: "text_delta", text: block.text },
                });
              }
            }
          }
        } catch {}
      }
    });

    proc.on("close", () => {
      emit({ type: "content_block_stop", index: 0 });
      emit({
        type: "message_delta",
        delta: { stop_reason: "end_turn", stop_sequence: null },
        usage: { output_tokens: 0 },
      });
      emit({ type: "message_stop" });
      res.write("data: [DONE]\n\n");
      res.end();
      console.log("✓ response complete");
    });

    proc.stderr.on("data", (d) => console.error("[claude]", d.toString().trim()));
  } else {
    let fullText = "";
    let buf = "";

    proc.stdout.on("data", (chunk) => {
      buf += chunk.toString();
      const lines = buf.split("\n");
      buf = lines.pop();
      for (const line of lines) {
        const t = line.trim();
        if (!t) continue;
        try {
          const ev = JSON.parse(t);
          if (ev.type === "assistant" && ev.message?.content) {
            fullText += ev.message.content
              .filter((b) => b.type === "text")
              .map((b) => b.text)
              .join("");
          }
          if (ev.type === "result" && ev.result) fullText = fullText || ev.result;
        } catch {}
      }
    });

    proc.on("close", () => {
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      });
      res.end(
        JSON.stringify({
          id: `msg_local_${Date.now()}`,
          type: "message",
          role: "assistant",
          content: [{ type: "text", text: fullText }],
          model: modelName,
          stop_reason: "end_turn",
          usage: { input_tokens: 0, output_tokens: 0 },
        })
      );
    });
  }
}

// ---------------------------------------------------------------------------
// /tts — forward to ElevenLabs
// ---------------------------------------------------------------------------
async function handleTTS(req, res) {
  const body = await readBody(req);
  const upstream = await httpsRequest(
    {
      hostname: "api.elevenlabs.io",
      path: `/v1/text-to-speech/${ELEVENLABS_VOICE_ID}`,
      method: "POST",
      headers: {
        "xi-api-key": ELEVENLABS_KEY,
        "Content-Type": "application/json",
        Accept: "audio/mpeg",
      },
    },
    body
  );
  res.writeHead(upstream.statusCode, { "Content-Type": "audio/mpeg" });
  upstream.pipe(res);
}

// ---------------------------------------------------------------------------
// /transcribe-token — forward to AssemblyAI
// ---------------------------------------------------------------------------
async function handleTranscribeToken(res) {
  const upstream = await httpsRequest({
    hostname: "streaming.assemblyai.com",
    path: "/v3/token?expires_in_seconds=480",
    method: "GET",
    headers: { Authorization: ASSEMBLYAI_KEY },
  });
  let data = "";
  upstream.on("data", (c) => (data += c));
  upstream.on("end", () => {
    res.writeHead(upstream.statusCode, { "Content-Type": "application/json" });
    res.end(data);
  });
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, x-api-key, anthropic-version, authorization");

  if (req.method === "OPTIONS") {
    res.writeHead(200);
    res.end();
    return;
  }

  const p = new URL(req.url, `http://localhost:${PORT}`).pathname;
  console.log(`${req.method} ${p}`);

  try {
    if (p === "/v1/messages") return await handleMessages(req, res);
    if (p === "/tts") return await handleTTS(req, res);
    if (p === "/transcribe-token") return await handleTranscribeToken(res);
    res.writeHead(404);
    res.end("Not found");
  } catch (err) {
    console.error("Handler error:", err);
    res.writeHead(500);
    res.end(err.message);
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`\n✅ Clicky proxy running at http://localhost:${PORT}`);
  console.log(`   claude binary: ${findClaude()}`);
  console.log(`   Intercepts:    /v1/messages → claude CLI`);
  console.log(`                  /tts → ElevenLabs`);
  console.log(`                  /transcribe-token → AssemblyAI\n`);
});
