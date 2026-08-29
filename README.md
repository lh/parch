# parch

Background PDF-to-markdown indexer for macOS. Finds PDFs on your machine, converts them to markdown so LLMs can read them, and keeps the index up to date.

## How it works

1. **Scan** `~/Documents` and `~/Code` (configurable) for PDFs using Spotlight plus a filesystem walk as a safety net
2. **Hash** each PDF (SHA-256) so duplicates can be symlinked instead of re-converted
3. **Convert** pending PDFs to markdown, storing output alongside each source file
4. **Track** everything in a SQLite index at `~/.parch/index.db`

Designed to run as a launchd background service on a schedule and/or on directory change.

## Requirements

- macOS 15+
- Swift 6.2+ (comes with Xcode / Command Line Tools)
- Optional: miniconda/miniforge with a `marker` environment (for the marker engine) and/or an `ovis` environment (for the ovis engine)

## Install

```sh
git clone https://github.com/lh/parch.git
cd parch
./scripts/build.sh
```

The binary is at `.build/release/parch`. Symlink it onto your PATH if you want, or run it directly.

**About `scripts/build.sh`:** it runs `swift build -c release` and then code-signs the binary with a Developer ID Application certificate if one is available on your system. Signing makes macOS's TCC (Privacy & Security) permissions stable across rebuilds — without it, each rebuild looks like a new app to macOS and you'll be re-prompted for folder access every time. If you don't have a Developer ID certificate the build still works, you just get TCC churn on rebuild. Set `PARCH_SIGNING_IDENTITY` to override which identity is used.

## Conversion engines

parch has three conversion engines. Auto mode (default) runs Vision first and, when its output is poor, retries with the engine suited to the document: marker for digital PDFs, ovis for scanned ones.

| Engine | Dependencies | Speed | Best for |
|--------|--------------|-------|----------|
| **vision** | None (system framework) | ~1s/page | Text-heavy docs, reports, papers |
| **marker** | conda + marker-pdf | ~30s/page with MPS | Slides, complex tables, math |
| **ovis** | conda + OvisOCR2 model | ~12-19s/page on MPS | Scanned docs with tables/math/structure |

### Vision (default)

Uses Apple's built-in OCR via `VNRecognizeTextRequest`. Zero setup, runs on the Neural Engine, handles the majority of documents at 92-98% quality compared to marker.

Works out of the box. Nothing to install.

### Marker (optional)

Uses [marker-pdf](https://github.com/datalab-to/marker) for high-fidelity conversion. Better for documents with complex layouts, mathematical notation, or tables.

To enable:

```sh
# Install miniforge (or miniconda)
brew install miniforge

# Create the marker env
conda create -n marker python=3.12 -y
conda activate marker
pip install marker-pdf
conda deactivate
```

parch auto-detects conda in standard locations (`/opt/homebrew/bin/conda`, `~/miniforge3/bin/conda`, etc.). If conda and the `marker` env exist, parch will use marker automatically in auto mode when Vision output is poor quality.

**Known issue on Apple Silicon:** surya-ocr (used by marker) has an MPS bug that crashes on certain tensor shapes. If you hit it, patch `.max().item()` call sites in the env's surya install to use `.cpu().max().item()` -- see [surya#493](https://github.com/VikParuchuri/surya/pull/493).

### Ovis (optional)

Uses [OvisOCR2](https://huggingface.co/ATH-MaaS/OvisOCR2), a 0.9B end-to-end page-image-to-markdown model (Apache 2.0, Qwen3.5-0.8B base). It always OCRs the rendered page, so its niche is scanned documents: on those it matches marker's structure quality (HTML tables, LaTeX formulas, code blocks) at roughly a third of marker's wall time. Auto mode uses it as the fallback for scanned documents when the `ovis` conda env is installed; it can also be requested directly with `--engine ovis`. It is never given documents where Vision finds no text at all — on pure-image pages it fabricates text instead of failing.

Measured on an M3 Max (2026-08-23), single dense page with code, a table, and math:

| Engine | Digital PDF (text layer) | Scanned page image |
|--------|--------------------------|--------------------|
| vision | ~0.5s, flat text, OCR dropouts | ~0.6s, same limits |
| marker | ~13s, exact (reads text layer) | ~61s, full structure |
| ovis   | ~18s, full structure | ~19s, full structure |

Plus ~7s model load per invocation for ovis. On digital PDFs marker is both faster and exact (it reads the text layer), so ovis earns its keep only where OCR is unavoidable. Being an LLM it can occasionally drop a character in dense code (observed: a `%` in a `sprintf` format string), where marker's OCR was exact.

The table shows engine-vs-engine numbers at normal priority. parch runs its Python engines at background priority (`nice -n 20` plus background QoS) so conversions never fight the foreground; on the same scanned page that cost ovis 3.3x wall time (85s vs 25s through the identical worker). Marker pays the same policy penalty, so the relative ordering holds.

To enable:

```sh
conda create -n ovis python=3.12 -y
conda run -n ovis pip install torch torchvision transformers accelerate pillow pypdfium2
```

The ~1.7GB model downloads from Hugging Face on first run. The Python worker script is embedded in the parch binary and written to `~/.parch/ovis_convert.py` at runtime, so there is nothing else to install. Runs on MPS (Apple Silicon GPU) automatically, falling back to CPU.

Two decode-loop guards are built into the worker (greedy decoding can repeat a paragraph forever on some pages): a repeat-detecting stopping criterion during generation, and block-level dedup plus the model card's character-level cleaner afterwards. Known trade-off: the stopping criterion can truncate a pathologically repetitive page (e.g. a form of many identical blank rows), since an exact 128-token repeat is indistinguishable from a decode loop mid-generation. The worker also pins both end-of-turn token ids explicitly — the upstream repo ships no `generation_config.json` and its config-level EOS differs from the chat template's, which otherwise sends every page into a runaway loop.

### Auto mode logic

1. Try Vision first
2. Vision writes `.vision-quality.json` sidecar with confidence score, character count, and garble ratio
3. If Vision found no text at all, mark the file failed. There is nothing to transcribe — and no fallback runs, because ovis fabricates plausible text for pure-image pages instead of failing (see `deep-dive/ovis-canary-devon-2026-08-24.md`)
4. If quality is acceptable (confidence ≥ 0.5, garble ratio ≤ 0.3, ≥ 100 chars/page), keep Vision output
5. If quality is poor, retry with the engine suited to the document class: documents with a real text layer go to marker (exact, fast); scanned documents (no text layer) go to ovis (faithful structure at a third of marker's OCR time). Whichever of the two is installed covers for the other
6. If neither fallback is installed, Vision output is kept regardless

## Usage

### One-off run

```sh
parch run                          # scan default roots, convert up to 50 pending
parch run --limit 200              # convert more per run
parch run --engine vision          # Vision only, no fallback
parch run --engine marker          # marker only, requires conda setup
parch run --engine ovis            # OvisOCR2 only, requires conda setup; best for scans
parch run --engine auto            # default: Vision primary; marker/ovis fallback by document class
parch run --root ~/Dropbox/Papers  # custom scan root
parch run --scan-only              # index without converting
```

### Useful commands

```sh
parch status                 # index summary (complete/pending/failed counts)
parch list-pending           # show PDFs waiting to convert
parch list-failed            # show PDFs that failed, with reasons
parch convert --limit 10     # convert without re-scanning
parch convert --path ~/x     # convert only files under a path
```

### Skip a directory

Drop a file called `.nomarker` in any directory. parch skips that directory and
its descendants — useful for repositories whose PDFs are test fixtures rather
than documents.

The exclusion is retroactive. The next scan also prunes anything already in the
index that now sits under the marker, so adding `.nomarker` to a directory parch
has already worked on stops the pending conversions rather than only preventing
new ones. `parch run` reports what it dropped:

```
Scan: 812 found, 0 new, 0 updated, 216 pruned
```

Pruning removes index entries, not files. Conversions parch already wrote stay
on disk; delete those yourself if you want them gone. Removing the marker lets
the next scan rediscover the directory from scratch.

### Source files take priority

parch automatically skips PDFs that have a sibling `.tex`, `.md`, `.markdown`, `.typ`, `.rst`, or `.rmd` file with the same name. No point converting a PDF back to markdown when the original source is right there.

## Running as a background service

parch is designed to run periodically via launchd. An example `com.parch.indexer.plist` is included in the repo.

### Install the service

The plist in the repo is a template — replace `YOUR_USERNAME` with your macOS short username before installing.

```sh
sed "s/YOUR_USERNAME/$(id -un)/g" com.parch.indexer.plist > ~/Library/LaunchAgents/com.parch.indexer.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.parch.indexer.plist

# Check it's loaded
launchctl print gui/$(id -u)/com.parch.indexer
```

### Uninstall

```sh
launchctl bootout gui/$(id -u)/com.parch.indexer
rm ~/Library/LaunchAgents/com.parch.indexer.plist
```

### What the plist does

- Runs `parch run` every hour (`StartInterval` 3600)
- Optionally fires when files change in a watched directory (`WatchPaths`)
- Runs at low priority (`LowPriorityIO`, `Nice 15`, `ProcessType Background`)
- Logs stdout/stderr to `~/.parch/parch.log`

A POSIX file lock (`~/.parch/parch.lock`) prevents overlapping runs, so it's safe to use `StartInterval` and `WatchPaths` together -- if parch is already running when a trigger fires, the new invocation exits immediately.

## Dedicated processor setup (e.g. Mac Mini)

If you have a spare Mac running 24/7, point it at a specific folder for offloaded processing. Add `--root` to the ProgramArguments and a `WatchPaths` key for near-instant triggering when files land in the folder:

```xml
<key>ProgramArguments</key>
<array>
    <string>/Users/YOUR_USERNAME/Code/OCR/parch/.build/release/parch</string>
    <string>run</string>
    <string>--root</string>
    <string>/Users/YOUR_USERNAME/Dropbox/ToConvert</string>
</array>

<key>WatchPaths</key>
<array>
    <string>/Users/YOUR_USERNAME/Dropbox/ToConvert</string>
</array>
```

Dropbox placeholder files (Smart Sync "online only") cannot be read until Dropbox materializes them locally: hashing fails with "Resource deadlock avoided" and the file is marked failed with that reason. Make the folder (or file) available offline in Dropbox, then reset the failed rows to retry (snippet under Troubleshooting).

## Data & paths

- **Index database:** `~/.parch/index.db` (SQLite, GRDB-managed migrations)
- **Log file:** `~/.parch/parch.log` (rotated at 5 MB, previous kept at `parch.log.1`)
- **Process lock:** `~/.parch/parch.lock`
- **Output:** Each PDF gets a sibling directory with the same stem, containing `<stem>.md`. E.g. `report.pdf` → `report/report.md`. Duplicates get symlinked to the canonical output directory.
- **Vision quality metadata:** `.vision-quality.json` sidecar inside each Vision-produced output directory

## Troubleshooting

**Files failed with "Resource deadlock avoided"**
The file is a cloud-provider placeholder (Dropbox "online only") that isn't materialized locally. Make it available offline, then reset the row with the snippet below. If *every* file fails this way on an old build, rebuild from main — early versions crashed the whole run on the first placeholder.

**Vision output looks garbled on slides**
Slide title graphics are hard for Vision OCR. Use `--engine marker` for those documents, or let auto mode fall back (ensure marker is installed).

**"marker not detected" in auto mode**
parch looks for conda at `/opt/homebrew/bin/conda`, `/usr/local/bin/conda`, `~/miniforge3/bin/conda`, `~/miniconda3/bin/conda`, `~/anaconda3/bin/conda`. Install conda in one of those locations.

**Service is stuck / same file taking hours**
Check `~/.parch/parch.log`. If marker is CPU-bound on a large PDF, it can take 30+ minutes per document. The process lock and `WatchPaths` prevent duplicate work.

**Reset a failed file to retry**
```sh
sqlite3 ~/.parch/index.db "UPDATE indexed_pdf SET conversion_status='pending', failure_reason=NULL WHERE file_path='/path/to/file.pdf';"
```

## License

MIT — see [LICENSE](LICENSE).
