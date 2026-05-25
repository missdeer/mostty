# /build — Build commands for this repo

## Go tools

Run from the repository root:

- macOS / Linux: `make`
- Windows: `mingw32-make.exe`

All binaries are emitted to `./bin/`. The top-level `Makefile` covers every Go tool under `tools/` and every Go app under `apps/`.

## Qt tool: `tools/crawler-webengine`

Cross-platform (Windows / macOS / Linux), built with CMake + Qt6 + Ninja. The Qt SDK is expected at `$HOME/Qt/6/<host>/` on macOS/Linux; on Windows it is discovered through the helper shell functions described below.

The build directory is `tools/crawler-webengine/cmake-build`. The output executable (`crawler-webengine` on macOS/Linux, `crawler-webengine.exe` on Windows) is emitted there, alongside Qt runtime libraries for in-place deployment.

### macOS

Run from `tools/crawler-webengine/`:

```bash
# 1. Remove stale cache (defensive — safe to run every time)
rm -rf cmake-build/CMakeCache.txt cmake-build/CMakeFiles

# 2. Configure
cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=$HOME/Qt/6/macos/lib/cmake/Qt6/qt.toolchain.cmake \
  -DCMAKE_MODULE_PATH=$PWD/cmake \
  -G Ninja \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_MAKE_PROGRAM=/opt/homebrew/bin/ninja \
  -S . -B cmake-build

# 3. Build
cmake --build cmake-build --parallel --verbose
```

Intel macs: substitute `/usr/local/bin/ninja` for `/opt/homebrew/bin/ninja`.

### Linux

Run from `tools/crawler-webengine/`:

```bash
# 1. Remove stale cache (defensive)
rm -rf cmake-build/CMakeCache.txt cmake-build/CMakeFiles

# 2. Configure
cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=$HOME/Qt/6/gcc_64/lib/cmake/Qt6/qt.toolchain.cmake \
  -DCMAKE_MODULE_PATH=$PWD/cmake \
  -G Ninja \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -S . -B cmake-build

# 3. Build
cmake --build cmake-build --parallel --verbose
```

`ninja` is taken from `PATH` (typically the distro package). Substitute `clang` / `clang++` if preferred. Adjust the toolchain path if your Qt install lives elsewhere.

### Windows

Windows uses two pre-configured bash shell functions — `cmake-build` and `cmake-reconfigure` — which wrap MSVC environment setup (`vcvarsall.bat`) and the CMake invocation. They are **not** CMake built-ins. Both depend on an internal helper `_cmake_ps` that is only defined when bash loads the user's login profile.

**Important**: inside Claude Code, these commands MUST be invoked via `bash -lc "..."` so the login shell loads `_cmake_ps`. A non-login shell reports `command not found`, and without the `vcvarsall` environment the compile fails to find MSVC headers such as `<type_traits>`.

```bash
# From the repository root — single argument is the build directory:
bash -lc "cmake-build tools/crawler-webengine/cmake-build"

# Equivalent, from inside tools/crawler-webengine/:
bash -lc "cd tools/crawler-webengine && cmake-build cmake-build"
```

A single `cmake-build` invocation performs both configure and build.

### When the build fails (any platform)

A common cause is a stale CMake cache.

**macOS / Linux**: re-run the macOS/Linux flow above — step 1 already wipes the cache.

**Windows**: re-run the reconfigure helper from inside `tools/crawler-webengine/`, then re-run `cmake-build`:

```bash
bash -lc "cd tools/crawler-webengine && cmake-reconfigure cmake-build"
bash -lc "cmake-build tools/crawler-webengine/cmake-build"
```

Notes:

- `cmake-reconfigure` is likewise a bash shell function, not a CMake built-in.
- It **must be run from inside `tools/crawler-webengine/`** with `cmake-build` as the build-directory argument.
- After reconfiguration succeeds, return to the repository root and re-run the `cmake-build` invocation.
