/**
 * Clicky Proxy Worker — Z.ai + OpenRouter backend
 *
 * Accepts Anthropic-format requests from the Swift app and proxies them to
 * Z.ai Codeplan (GLM 5.1) as primary, with OpenRouter as fallback.
 * Converts the OpenAI SSE response back to Anthropic-format SSE so
 * ClaudeAPI.swift needs no changes.
 *
 * Routes:
 *   POST /chat             → OpenRouter chat completions (streaming)
 *   POST /tts              → ElevenLabs TTS (optional — returns 501 if unconfigured)
 *   POST /transcribe-token → AssemblyAI temp token (unused when Apple Speech is active)
 */

interface Env {
  OPENROUTER_API_KEY: string;
  OPENROUTER_MODEL?: string;        // defaults to nvidia/llama-3.1-nemotron-ultra-253b-v1:free
  ZHIPU_API_KEY?: string;           // Z.ai Codeplan API key — uses GLM 5.1 as primary model
  ZHIPU_MODEL?: string;             // defaults to glm-5.1
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
  ASSEMBLYAI_API_KEY?: string;
}

// Ordered fallback list — the worker tries each in sequence on 429 rate-limit errors.
// All support vision (image input) and are free on OpenRouter.
// Spread across multiple providers so a single provider outage doesn't block all models.
const MODEL_FALLBACK_CHAIN = [
  "openai/gpt-4o",                        // GPT-4o — strong vision support, fast
  "openai/gpt-4o-mini",                   // GPT-4o mini fallback — cheaper, still has vision
  "nvidia/nemotron-nano-12b-v2-vl:free", // NVIDIA free-tier vision fallback
];

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }
      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }
      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

// ---------------------------------------------------------------------------
// /chat — converts Anthropic-format request → OpenRouter, then converts the
//         OpenAI SSE response back to Anthropic SSE format for ClaudeAPI.swift
// ---------------------------------------------------------------------------

async function handleChat(request: Request, env: Env): Promise<Response> {
  const anthropicBody = await request.json() as Record<string, unknown>;

  // Pull system prompt out of the top-level "system" field (Anthropic format)
  const systemPrompt = anthropicBody["system"] as string | undefined;
  const anthropicMessages = (anthropicBody["messages"] ?? []) as Array<{
    role: string;
    content: string | Array<{ type: string; text?: string; source?: { type: string; media_type: string; data: string } }>;
  }>;
  const maxTokens = (anthropicBody["max_tokens"] as number | undefined) ?? 1024;
  // env.OPENROUTER_MODEL overrides the chain; otherwise work through fallbacks
  const modelChain = env.OPENROUTER_MODEL
    ? [env.OPENROUTER_MODEL]
    : MODEL_FALLBACK_CHAIN;

  // Build OpenAI-compatible messages array
  const openaiMessages: Array<{ role: string; content: string }> = [];

  // Convert each Anthropic message to OpenAI format.
  // Images are converted from Anthropic's base64 source format to OpenAI's image_url format.
  // System prompt is injected as a text block in the first user message to ensure
  // compatibility with models that don't support system-role messages (e.g. Gemma via AI Studio).
  let systemPromptInjected = false;

  for (const msg of anthropicMessages) {
    const openaiContentBlocks: Array<unknown> = [];

    // Inject the system prompt as the first text block of the first user message
    if (msg.role === "user" && !systemPromptInjected && systemPrompt) {
      openaiContentBlocks.push({
        type: "text",
        text: `[System instructions: ${systemPrompt}]\n\n`,
      });
      systemPromptInjected = true;
    }

    if (typeof msg.content === "string") {
      openaiContentBlocks.push({ type: "text", text: msg.content });
    } else {
      for (const block of msg.content) {
        if (block.type === "text" && block.text) {
          openaiContentBlocks.push({ type: "text", text: block.text });
        } else if (block.type === "image" && block.source?.type === "base64") {
          // Anthropic: {"type":"image","source":{"type":"base64","media_type":"...","data":"..."}}
          // OpenAI:    {"type":"image_url","image_url":{"url":"data:<media_type>;base64,<data>"}}
          openaiContentBlocks.push({
            type: "image_url",
            image_url: {
              url: `data:${block.source.media_type};base64,${block.source.data}`,
            },
          });
        }
      }
    }

    openaiMessages.push({ role: msg.role, content: openaiContentBlocks as unknown as string });
  }

  // Try Z.ai (GLM 5.1) first if configured, then fall back to OpenRouter
  let upstreamResponse: Response | null = null;
  let lastErrorBody = "";

  // --- Z.ai Codeplan (primary) ---
  if (env.ZHIPU_API_KEY) {
    const zhipuModel = env.ZHIPU_MODEL ?? "glm-5.1";
    const zhipuBody = {
      model: zhipuModel,
      max_tokens: maxTokens,
      stream: true,
      messages: openaiMessages,
    };

    console.log(`[/chat] Trying Z.ai model=${zhipuModel}`);

    try {
      const response = await fetch(
        "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${env.ZHIPU_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(zhipuBody),
        }
      );

      if (response.ok) {
        upstreamResponse = response;
        console.log(`[/chat] Z.ai ${zhipuModel} succeeded`);
      } else {
        lastErrorBody = await response.text();
        console.error(`[/chat] Z.ai ${zhipuModel} failed (${response.status}): ${lastErrorBody.slice(0, 120)}`);
      }
    } catch (err) {
      console.error(`[/chat] Z.ai fetch error:`, err);
    }
  }

  // --- OpenRouter fallback ---
  if (!upstreamResponse) {
    for (const model of modelChain) {
      const openaiBody = {
        model,
        max_tokens: maxTokens,
        stream: true,
        messages: openaiMessages,
      };

      console.log(`[/chat] Trying OpenRouter model=${model}`);

      const response = await fetch(
        "https://openrouter.ai/api/v1/chat/completions",
        {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${env.OPENROUTER_API_KEY}`,
            "Content-Type": "application/json",
            "HTTP-Referer": "https://clicky.local",
            "X-Title": "Clicky",
          },
          body: JSON.stringify(openaiBody),
        }
      );

      if (response.ok) {
        upstreamResponse = response;
        break;
      }

      lastErrorBody = await response.text();
      console.error(`[/chat] Model ${model} failed (${response.status}): ${lastErrorBody.slice(0, 120)}`);

      // Retry on rate-limit (429), model-not-found (404), or invalid model (400)
      if (response.status !== 429 && response.status !== 404 && response.status !== 400) {
        return new Response(lastErrorBody, {
          status: response.status,
          headers: { "content-type": "application/json" },
        });
      }
    }
  }

  if (!upstreamResponse) {
    return new Response(lastErrorBody || "All models failed", {
      status: 429,
      headers: { "content-type": "application/json" },
    });
  }

  // Transform the OpenAI SSE stream into Anthropic SSE format on-the-fly.
  // ClaudeAPI.swift expects lines like:
  //   data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
  // and terminates on:
  //   data: [DONE]
  //
  // SSE events can be split across multiple chunks, so we buffer incomplete
  // lines and only process complete ones (terminated by "\n").
  let lineBuffer = "";

  const transformedStream = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      lineBuffer += new TextDecoder().decode(chunk);

      // Split on newlines, keeping any trailing incomplete line in the buffer
      const lines = lineBuffer.split("\n");
      lineBuffer = lines.pop() ?? ""; // last element may be an incomplete line

      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;

        const payload = line.slice(6).trim(); // drop "data: "

        if (payload === "[DONE]") {
          // Pass through the [DONE] sentinel — ClaudeAPI.swift breaks on it
          controller.enqueue(new TextEncoder().encode("data: [DONE]\n\n"));
          continue;
        }

        try {
          const event = JSON.parse(payload) as {
            choices?: Array<{ delta?: { content?: string; reasoning?: string } }>;
          };

          const delta = event.choices?.[0]?.delta;
          // Only forward the model's final answer (`content`). We intentionally
          // drop `delta.reasoning` — that field carries the model's internal
          // chain-of-thought on reasoning-capable OpenRouter models (e.g.
          // nvidia/nemotron-*). If we forwarded it, ClaudeAPI.swift would
          // accumulate <reasoning><answer> into one blob and `/usr/bin/say`
          // would read both, which sounds like two voices / a broken pipeline.
          const textChunk = delta?.content;
          if (textChunk) {
            // Emit an Anthropic-style content_block_delta event
            const anthropicEvent = JSON.stringify({
              type: "content_block_delta",
              delta: { type: "text_delta", text: textChunk },
            });
            controller.enqueue(
              new TextEncoder().encode(`data: ${anthropicEvent}\n\n`)
            );
          }
        } catch {
          // Malformed JSON in SSE line — skip silently
        }
      }
    },
  });

  upstreamResponse.body!.pipeTo(transformedStream.writable).catch((err) => {
    console.error("[/chat] Stream pipe error:", err);
  });

  return new Response(transformedStream.readable, {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

// ---------------------------------------------------------------------------
// /tts — ElevenLabs proxy (optional; returns 501 if key not configured)
// ---------------------------------------------------------------------------

async function handleTTS(request: Request, env: Env): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY) {
    return new Response(
      JSON.stringify({ error: "TTS not configured (no ELEVENLABS_API_KEY)" }),
      { status: 501, headers: { "content-type": "application/json" } }
    );
  }

  const voiceId = env.ELEVENLABS_VOICE_ID ?? "kPzsL2i3teMYv0FxEYQ6";
  const body = await request.text();

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") ?? "audio/mpeg",
    },
  });
}

// ---------------------------------------------------------------------------
// /transcribe-token — AssemblyAI temp token (unused when Apple Speech active)
// ---------------------------------------------------------------------------

async function handleTranscribeToken(env: Env): Promise<Response> {
  if (!env.ASSEMBLYAI_API_KEY) {
    return new Response(
      JSON.stringify({ error: "AssemblyAI not configured" }),
      { status: 501, headers: { "content-type": "application/json" } }
    );
  }

  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: { authorization: env.ASSEMBLYAI_API_KEY },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(await response.text(), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}
