# Third-party notices (Windows)

Useful Voice is MIT licensed ([LICENSE](../LICENSE)). The Windows app includes or downloads the
following. Every license and notice file is kept verbatim under [licenses/](licenses) and ships in
the installer under `resources\licenses`. The npm packages the runtime pulls in keep their own
license files inside `node_modules`.

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

## node-llama-cpp

Runs S1-mini on Windows (npm package `node-llama-cpp` 3.22.1 and its prebuilt binaries in
`@node-llama-cpp/win-x64`), from [withcatai/node-llama-cpp](https://github.com/withcatai/node-llama-cpp).
MIT License, Copyright (c) 2023 and 2024 Gilad S.

- [licenses/node-llama-cpp/LICENSE](licenses/node-llama-cpp/LICENSE)
- [licenses/node-llama-cpp/LICENSE-win-x64-binaries](licenses/node-llama-cpp/LICENSE-win-x64-binaries)

## llama.cpp

The inference engine inside the node-llama-cpp binaries, from
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp). MIT License, Copyright (c) 2023-2026
The ggml authors.

- [licenses/llama.cpp/LICENSE](licenses/llama.cpp/LICENSE)
