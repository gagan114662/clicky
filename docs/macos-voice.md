# macOS Voice

The fallback speaker uses `/usr/bin/say` so it does not fight the microphone
audio engine. By default, ipop uses the warmer built-in macOS voice `Samantha`
at a slower rate.

## Local Overrides

```sh
defaults write ai.ipop.mac MacOSVoiceName "Samantha"
defaults write ai.ipop.mac MacOSVoiceRate "178"
```

Try other installed voices:

```sh
say -v '?' | grep en_US
say -v Samantha -r 178 "hey, i'm here. what should we work on?"
```

To reset to the app default:

```sh
defaults delete ai.ipop.mac MacOSVoiceName
defaults delete ai.ipop.mac MacOSVoiceRate
```
