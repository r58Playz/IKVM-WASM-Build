# ikvm-wasm-build

Build pipeline for producing IKVM runtime artifacts without consuming the published `IKVM` package in downstream apps.

Everything is driven directly from the GitHub Action script at:

- `.github/workflows/ikvm-wasm-build.yml`

The workflow script builds:

1. Managed IKVM outputs from the fork (`tools/ikvm/ikvm`): the runtime, ikvmc, and JDK 25's class library, which the
   JDK's own make builds (it needs a JDK 25 to boot from).
2. The WASM native libraries (IKVM's `libjvm` and `libikvm`, and the JDK's) via Emscripten.

Both go into one release zip, `ikvm-wasm-bundle.zip` (`tools/ikvm/build-ikvm-local.sh` builds it locally). The last
commit that builds the JDK 8 class library is tagged `jdk8-last`.
