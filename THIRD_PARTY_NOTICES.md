# Third-party notices

This file is what the macOS app ships. The Windows installer ships `windows/THIRD_PARTY_NOTICES.md`
(both in this repository).

Useful Voice is MIT licensed ([LICENSE](LICENSE)). The macOS app includes the following.
Every license file is kept verbatim under [licenses/](licenses), and both are copied into
`Contents/Resources` by `make bundle` and `make bundle-release`.

## whisper.cpp

Runs local transcription on macOS (`whisper.xcframework`, release v1.9.2, from
[ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)). MIT License, Copyright (c) 2023-2026
The ggml authors.

- [licenses/whisper.cpp/LICENSE](licenses/whisper.cpp/LICENSE)
