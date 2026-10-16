# Third-party notices

Useful Voice is MIT licensed ([LICENSE](LICENSE)). It includes or downloads the following.
Every license and notice file is kept verbatim under [licenses/](licenses).

This root file and `licenses/` are what the macOS app ships (copied into `Contents/Resources` by
`make bundle` and `make bundle-release`). The Windows installer ships
[windows/THIRD_PARTY_NOTICES.md](windows/THIRD_PARTY_NOTICES.md) and `windows/licenses/` instead; the
two overlap on purpose, so each package is complete on its own.

## S1-mini by Superwhisper

The optional local cleanup model (hidden for now). It is downloaded on request, not bundled.
S1-mini is a Qwen3-0.6B fine-tune (Copyright 2024 Alibaba Cloud, Apache License 2.0),
GGUF build `superwhisper/s1-mini-GGUF` at revision `34add00a48a2e5d24e5a4ee5405a99620a3a240c`,
Copyright 2026 Superwhisper.

License: Apache License 2.0 plus one additional term: the model must always be identified by its
original name, "S1-mini" by "Superwhisper", with that exact capitalisation, wherever it is used.
Credit here and in the app: **S1-mini by Superwhisper**.

- [licenses/s1-mini/LICENSE](licenses/s1-mini/LICENSE)
- [licenses/s1-mini/NOTICE](licenses/s1-mini/NOTICE)

## whisper.cpp

Runs local transcription on macOS (`whisper.xcframework`, release v1.9.2, from
[ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)). MIT License, Copyright (c) 2023-2026
The ggml authors.

- [licenses/whisper.cpp/LICENSE](licenses/whisper.cpp/LICENSE)

## llama.cpp

Runs S1-mini on macOS (`llama.xcframework`, release b11669, from
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)). MIT License, Copyright (c) 2023-2026
The ggml authors.

- [licenses/llama.cpp/LICENSE](licenses/llama.cpp/LICENSE)

The Windows runtime (node-llama-cpp and its dependencies) has its own notices in [windows/THIRD_PARTY_NOTICES.md](windows/THIRD_PARTY_NOTICES.md).
