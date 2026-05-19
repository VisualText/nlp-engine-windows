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

## How releases are produced

The [`nlp-engine-build.yml`](.github/workflows/nlp-engine-build.yml) workflow keeps this repo in sync with upstream:

1. Queries `VisualText/nlp-engine` for the latest GitHub release.
2. Downloads the Windows assets — `nlpengine.zip` (the `data/` tree), `nlpw.exe`, and the three ICU DLLs (`icudt*.dll`, `icuuc*.dll`, `icuin*.dll`). Asset matching is version-agnostic, so ICU bumps don't require workflow edits.
3. Removes the previously committed binaries in a dedicated cleanup commit (so git stores a clean diff rather than two layered binary blobs).
4. Unzips `nlpengine.zip`, renames `nlpw.exe` → `nlp.exe`, and commits the new files.
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
