# Third-party notices

Useful Voice is MIT licensed ([LICENSE](LICENSE)). It includes or downloads the following.
Every license and notice file is kept verbatim under [licenses/](licenses).

This root file and `licenses/` are what the macOS app ships (copied into `Contents/Resources` by
`make bundle` and `make bundle-release`). The Windows installer ships its
own copy of the notices (`windows/THIRD_PARTY_NOTICES.md` and `windows/licenses/` in the repository) instead; the
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

## llama.cpp

Runs S1-mini on macOS (`llama.xcframework`, release b11669, from
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)). MIT License, Copyright (c) 2023-2026
The ggml authors.

- [licenses/llama.cpp/LICENSE](licenses/llama.cpp/LICENSE)

The Windows runtime (node-llama-cpp and its dependencies) has its own notices in `windows/THIRD_PARTY_NOTICES.md` in the repository.

## FluidAudio

Runs the Parakeet models on macOS through Core ML (the `FluidAudio` Swift package, release 0.17.7,
from [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)). Apache License 2.0,
Copyright FluidInference. The package statically links the NeMo text normalization library
(Apache-2.0, built on NVIDIA NeMo Text Processing) and fastcluster (BSD), and carries VBx code; their
notices come with it.

- [licenses/fluidaudio/LICENSE](licenses/fluidaudio/LICENSE)
- [licenses/fluidaudio/NemoTextProcessing-LICENSE.md](licenses/fluidaudio/NemoTextProcessing-LICENSE.md)
- [licenses/fluidaudio/fastcluster-LICENSE.md](licenses/fluidaudio/fastcluster-LICENSE.md)
- [licenses/fluidaudio/vbx-LICENSE.md](licenses/fluidaudio/vbx-LICENSE.md)

## NVIDIA Parakeet TDT 0.6B v2 and v3

The Parakeet voice models (`parakeet-tdt-0.6b-v2` and `-v3`) are by NVIDIA, licensed under
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode), and are downloaded on request in
the Core ML conversion by FluidInference
([v2](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml),
[v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)). The conversion changes the format
and quantizes the weights. NVIDIA does not endorse Useful Voice.

- [licenses/parakeet/NOTICE](licenses/parakeet/NOTICE)
