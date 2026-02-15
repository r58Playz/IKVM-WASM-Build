# ikvm-wasm-build

Build pipeline for producing IKVM runtime artifacts without consuming the published `IKVM` package in downstream apps.

Everything is driven directly from the GitHub Action script at:

- `.github/workflows/ikvm-wasm-build.yml`

The workflow script builds:

1. Managed IKVM outputs (packed then extracted from local IKVM build).
2. Experimental WASM native artifacts for `libjvm` and `libikvm` via Emscripten.
