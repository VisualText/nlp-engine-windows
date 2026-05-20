# NLP Engine for Windows

Prebuilt Windows binaries of the [VisualText NLP Engine](https://github.com/VisualText/nlp-engine), packaged together with the `data/` knowledge bases and a Python wrapper so the engine can be downloaded and used out of the box — no compilation required.

The NLP Engine is the runtime for [NLP++](https://visualtext.org/), a domain-specific language for natural-language analyzers. This repository tracks upstream releases automatically and republishes them as a Windows-ready bundle.

## Companion Repositories

The NLP Engine is distributed per platform. Pick the one that matches your OS:

| Platform | Repository |
|----------|------------|
| Windows  | [VisualText/nlp-engine-windows](https://github.com/VisualText/nlp-engine-windows) (this repo) |
| Linux    | [VisualText/nlp-engine-linux](https://github.com/VisualText/nlp-engine-linux) |
| macOS    | [VisualText/nlp-engine-mac](https://github.com/VisualText/nlp-engine-mac) |
| Source   | [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine) |

For production use from Python, prefer the [NLPPlus Python package](https://github.com/VisualText/py-package-nlpengine) instead of the simple wrapper shipped here.

## Repository contents

| Path | Description |
|------|-------------|
| `nlp.exe` | The NLP Engine command-line executable (renamed from upstream `nlpw.exe`). |
| `icudt*.dll`, `icuuc*.dll`, `icuin*.dll` | ICU runtime DLLs that `nlp.exe` links against. The version suffix (74, 78, …) tracks whichever ICU upstream is currently using. |
| `data/` | NLP Engine data directory containing the `rfb` (rules-from-builder) knowledge base. `nlp.exe` is invoked with this directory as `-WORK`. |
| `compile-libs/` | Headers (`include/Api/`, `include/cs/`) and engine static libraries (`lib/{prim,kbm,consh,words,lite}.lib`) used to link a compiled analyzer/KB into a `.dll`. Populated by the workflow from upstream's `nlpengine-compile-libs.zip`. |
| `scripts/compile-analyzer.{ps1,bat}` | Compile an analyzer + KB into `<analyzer>\<name>.dll`. |
| `scripts/compile-kb.{ps1,bat}` | Rebuild only the KB into `<analyzer>\<name>_kb.dll`. |
| `python/` | Git submodule pointing at [VisualText/python](https://github.com/VisualText/python) — a thin Python wrapper (`NLPEngine` class) that shells out to `nlp.exe`. |
| `.version-flag` | Records the upstream release tag currently vendored (e.g. `v3.0.2`). Used by the update workflow to detect stale builds. |
| `.github/workflows/nlp-engine-build.yml` | Automation that pulls the latest upstream release and commits/tags it here. |

## Quick start

### Option 1: Download a release

Grab the latest tagged release from this repository's [Releases page](https://github.com/VisualText/nlp-engine-windows/releases). The tag mirrors the upstream `VisualText/nlp-engine` version (e.g. `v3.1.9`).

### Option 2: Clone the repository

```powershell
git clone --recurse-submodules https://github.com/VisualText/nlp-engine-windows.git
cd nlp-engine-windows
```

The `--recurse-submodules` flag pulls in the `python/` submodule. If you forgot it, run:

```powershell
git submodule update --init --recursive
```

### Running nlp.exe

`nlp.exe` is invoked with an analyzer folder, a working directory containing the `data/` tree, and an input text file:

```powershell
.\nlp.exe -ANA <path-to-analyzer-folder> -WORK <path-to-this-repo> <path-to-input-text-file>
```

Add `-DEV` to enable developer logging output.

`nlp.exe` and the ICU DLLs must remain in the same folder — Windows resolves the DLLs from the executable's directory at load time.

## Using from Python

The bundled `python/` submodule contains an `NLPEngine` class that wraps the executable for scripting use. See [`python/README.md`](python/README.md) for details. Minimal example:

```python
from python.nlpengine import NLPEngine

engine = NLPEngine(
    engineDir=r"C:\path\to\nlp-engine-windows",
    analyzersDir=r"C:\path\to\analyzers",
)
engine.analyzeInput("my-analyzer", "sample.txt")
```

For production workloads, prefer the [NLPPlus Python package](https://github.com/VisualText/py-package-nlpengine), which links against the engine directly instead of shelling out.

## Compiling an analyzer to a native DLL

By default `nlp.exe` runs analyzers interpreted from their `.nlp` spec files. For faster startup and execution, an analyzer (and its KB) can be compiled to a native `.dll` that `nlp.exe -COMPILED` loads at runtime. Two scripts in [`scripts/`](scripts/) drive this end-to-end:

| Script | What it does | Output |
|--------|--------------|--------|
| [`scripts/compile-analyzer.ps1`](scripts/compile-analyzer.ps1) | Runs `nlp.exe -COMPILE` to emit `<analyzer>\run\*.cpp` and `<analyzer>\kb\*.cpp`, generates a CMakeLists.txt, and links them against `compile-libs/` to produce a shared library. | `<analyzer>\<analyzer-name>.dll` |
| [`scripts/compile-kb.ps1`](scripts/compile-kb.ps1) | Runs `nlp.exe -COMPILEKB` (KB only — leaves analyzer rules untouched) and builds just `<analyzer>\kb\*.cpp`. | `<analyzer>\<analyzer-name>_kb.dll` |

Each `.ps1` ships with a `.bat` shim of the same name, so the scripts can be run either directly from PowerShell or from `cmd.exe`.

### Prerequisites

- Visual Studio 2022 (or Build Tools) with the **Desktop development with C++** workload — provides `cl.exe`, `lib.exe`, `dumpbin.exe`, and `VsDevCmd.bat`. The script locates these automatically via `vswhere.exe`.
- CMake ≥ 3.16 (on `PATH`).

### Usage

```powershell
# Compile the bundled rfb analyzer:
.\scripts\compile-analyzer.ps1 data\rfb data\rfb\input\text.txt

# Or from cmd.exe via the .bat shim:
scripts\compile-analyzer.bat data\rfb data\rfb\input\text.txt

# Run the compiled analyzer:
.\nlp.exe -COMPILED -ANA data\rfb -WORK . data\rfb\input\text.txt
```

### How ICU is linked

Upstream only ships ICU as runtime DLLs (`icudt78.dll`, `icuin78.dll`, `icuuc78.dll`) — no `.lib` import libraries. On its first run, `compile-analyzer.ps1` generates the import libs from the DLLs:

1. `dumpbin /exports icu*.dll` lists every exported symbol.
2. The exports are written to a `.def` file under `compile-libs\lib\`.
3. `lib.exe /def:... /machine:X64 /out:icu*.lib` produces the import library.

Subsequent runs reuse the generated `.lib` files. The ICU version digits (`78`) match the bundled DLLs and will move in lock-step whenever upstream bumps ICU.

## How releases are produced

The [`nlp-engine-build.yml`](.github/workflows/nlp-engine-build.yml) workflow keeps this repo in sync with upstream:

1. Queries `VisualText/nlp-engine` for the latest GitHub release.
2. Downloads the Windows assets — `nlpengine.zip` (the `data/` tree), `nlpw.exe`, the three ICU DLLs (`icudt*.dll`, `icuuc*.dll`, `icuin*.dll`), and `nlpengine-compile-libs.zip` (headers + engine static libraries used by the compile scripts; optional — skipped if absent on a given release). Asset matching is version-agnostic, so ICU bumps don't require workflow edits.
3. Removes the previously committed binaries in a dedicated cleanup commit (so git stores a clean diff rather than two layered binary blobs).
4. Unzips `nlpengine.zip`, renames `nlpw.exe` → `nlp.exe`, extracts `nlpengine-compile-libs.zip` to `compile-libs/`, and commits the new files.
5. Tags the commit with the upstream version and publishes a GitHub release.

### Triggers

- **`repository_dispatch`** with event type `nlp-engine-release` — fired by the upstream repo on every new release.
- **`workflow_dispatch`** — manual trigger from the Actions tab. Forces an update even if the tag already exists locally.

### When the workflow fails

If `actions/github-script` throws `Could not find <asset> in release …`, an upstream asset has been renamed. The error message includes the full list of available assets — update the matcher in `nlp-engine-build.yml` (the `findAsset` calls) to reflect the new name.

## Related repositories

- [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine) — upstream source for the engine itself.
- [VisualText/nlp-engine-linux](https://github.com/VisualText/nlp-engine-linux) — Linux binary bundle.
- [VisualText/nlp-engine-mac](https://github.com/VisualText/nlp-engine-mac) — macOS binary bundle.
- [VisualText/py-package-nlpengine](https://github.com/VisualText/py-package-nlpengine) — production-grade Python bindings.
- [VisualText NLP++ VSCode Extension](https://marketplace.visualstudio.com/items?itemName=dehilster.nlp) — IDE integration that drives `nlp.exe`.

## License

MIT — matches the upstream NLP Engine license.
