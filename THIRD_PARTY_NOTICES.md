# Third-party notices

Useful Voice is MIT licensed ([LICENSE](LICENSE)). It includes or downloads the following.
Every license and notice file is kept verbatim under [licenses/](licenses).

This root file and `licenses/` are what the macOS app ships (copied into `Contents/Resources` by
`make bundle` and `make bundle-release`).

## whisper.cpp

Runs local transcription on macOS (embedded as `whisper.framework` from the v1.9.2 `whisper.xcframework` release of
[ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)). MIT License, Copyright (c) 2023-2026
The ggml authors.

- [licenses/whisper.cpp/LICENSE](licenses/whisper.cpp/LICENSE)

## Whisper model weights

The local transcription engine downloads one of two models on request, not bundled: OpenAI
Whisper large-v3-turbo (MIT License) or large-v3 (Apache License 2.0). The files are the ggml
conversions published at [huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)
(model card license: MIT). The app checks each download against a pinned SHA-256. The models are
by OpenAI; see the model cards
([whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo),
[whisper-large-v3](https://huggingface.co/openai/whisper-large-v3)).

## Sparkle

Checks for and installs updates in release builds of the macOS app (`Sparkle.framework`, release
2.10.0, from [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)). MIT License,
Copyright (c) 2006-2013 Andy Matuschak and the other authors listed in the license, which also
carries the licenses of the code Sparkle includes (bsdiff, sais and others).

- [licenses/Sparkle/LICENSE](licenses/Sparkle/LICENSE)
