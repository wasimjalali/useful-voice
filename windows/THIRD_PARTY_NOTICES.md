# Third-party notices

Useful Voice for Windows is MIT licensed. It includes or downloads the following.

## sherpa-onnx

Runs the local Parakeet models. Bundled as the `sherpa-onnx-node` addon and its `sherpa-onnx-win-x64`
native library (version 1.13.8) from [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx).
Copyright k2-fsa authors. Licensed under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0). The package also carries ONNX Runtime
(Copyright Microsoft Corporation, MIT License).

## NVIDIA Parakeet TDT 0.6B v2 and v3

The optional local transcription models, downloaded on request, not bundled. They are the int8
conversions published by sherpa-onnx of NVIDIA's
[parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) and
[parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
Copyright NVIDIA Corporation. Licensed under the Creative Commons Attribution 4.0 International
License (CC-BY-4.0, https://creativecommons.org/licenses/by/4.0/). The converted files are
changed from the originals (int8 quantisation, ONNX export).
