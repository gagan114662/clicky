# Orchestration Resilience

The response pipeline now retries only the provider call inside a voice turn.
By the time the retry wrapper runs, ipop has already captured the transcript,
optional screenshots, memory context, and routing decision. A retry therefore
does not restart dictation, recapture the screen, re-run local intent routing,
or duplicate the entire workflow.

## Retried Failures

- HTTP `429` rate limits, honoring `Retry-After` when providers send it.
- Temporary HTTP failures: `408`, `409`, `425`, `500`, `502`, `503`, `504`.
- URL/network timeouts and transient connection interruptions.
- Provider response parse failures such as invalid response envelopes or empty
  streamed output.

## Not Retried

- User cancellation.
- Authentication/configuration problems such as `401` or `403`.
- Non-transient provider errors.

## Attempts

The default policy makes up to three provider attempts with short exponential
backoff. The provider wrapper is shared by Z.ai, Claude API, Claude proxy, and
Claude CLI fallback paths.
