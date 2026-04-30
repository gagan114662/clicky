# Z.ai Provider

ipop can use Z.ai for normal voice responses and screenshot-aware turns without going through the Claude CLI.

## Enable Locally

```sh
defaults write ai.ipop.mac AIProvider zai
defaults write ai.ipop.mac ZAIAPIKey '<your-zai-api-key>'
```

Optional model overrides:

```sh
defaults write ai.ipop.mac ZAITextModel glm-4.5
defaults write ai.ipop.mac ZAIVisionModel glm-4.5v
```

To disable and return to the Claude provider chain:

```sh
defaults delete ai.ipop.mac AIProvider
```

## Environment Overrides

For command-line launches or CI smoke tests:

```sh
IPOP_AI_PROVIDER=zai \
IPOP_ZAI_API_KEY='<your-zai-api-key>' \
open /Applications/ipop.ai.app
```

Supported env vars:

- `IPOP_AI_PROVIDER`
- `IPOP_ZAI_API_KEY`
- `IPOP_ZAI_ENDPOINT_URL`
- `IPOP_ZAI_TEXT_MODEL`
- `IPOP_ZAI_VISION_MODEL`

## Notes

- Text turns default to `glm-4.5`.
- Screenshot turns default to `glm-4.5v`.
- Existing Claude proxy/OAuth/CLI behavior remains the fallback when Z.ai is not explicitly enabled.
- Codex agent sessions are separate; this provider does not replace Codex app-server authentication.
