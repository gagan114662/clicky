# Z.ai Provider

ipop can use Z.ai for normal voice responses and screenshot-aware turns without going through the Claude CLI.

## Enable Locally

```sh
defaults write com.yourcompany.leanring-buddy ClickyAIProvider zai
defaults write com.yourcompany.leanring-buddy ClickyZAIAPIKey '<your-zai-api-key>'
```

Optional model overrides:

```sh
defaults write com.yourcompany.leanring-buddy ClickyZAITextModel glm-4.5
defaults write com.yourcompany.leanring-buddy ClickyZAIVisionModel glm-4.5v
```

To disable and return to the Claude provider chain:

```sh
defaults delete com.yourcompany.leanring-buddy ClickyAIProvider
```

## Environment Overrides

For command-line launches or CI smoke tests:

```sh
CLICKY_AI_PROVIDER=zai \
CLICKY_ZAI_API_KEY='<your-zai-api-key>' \
open /path/to/Clicky.app
```

Supported env vars:

- `CLICKY_AI_PROVIDER`
- `CLICKY_ZAI_API_KEY`
- `CLICKY_ZAI_ENDPOINT_URL`
- `CLICKY_ZAI_TEXT_MODEL`
- `CLICKY_ZAI_VISION_MODEL`

## Notes

- Text turns default to `glm-4.5`.
- Screenshot turns default to `glm-4.5v`.
- Existing Claude proxy/OAuth/CLI behavior remains the fallback when Z.ai is not explicitly enabled.
- Codex agent sessions are separate; this provider does not replace Codex app-server authentication.
