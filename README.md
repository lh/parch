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
- Optional: miniconda/miniforge with a `marker` environment (for the marker engine)

## Install

```sh
git clone https://github.com/lh/parch.git
cd parch
swift build -c release
```

The binary is at `.build/release/parch`. Symlink it onto your PATH if you want, or run it directly.

## Conversion engines

parch has two conversion engines. Auto mode (default) picks the best one per file.

| Engine | Dependencies | Speed | Best for |
|--------|--------------|-------|----------|
| **vision** | None (system framework) | ~1s/page | Text-heavy docs, reports, papers |
| **marker** | conda + marker-pdf | ~30s/page with MPS | Slides, complex tables, math |

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

### Auto mode logic

1. Try Vision first
2. Vision writes `.vision-quality.json` sidecar with confidence score, character count, and garble ratio
3. If quality is acceptable (confidence ≥ 0.5, garble ratio ≤ 0.3, ≥ 100 chars/page), keep Vision output
4. If quality is poor **and** marker is available, delete Vision output and retry with marker
5. If marker isn't installed, Vision output is kept regardless

## Usage

### One-off run

```sh
parch run                          # scan default roots, convert up to 50 pending
parch run --limit 200              # convert more per run
parch run --engine vision          # Vision only, never marker
parch run --engine marker          # marker only, requires conda setup
parch run --engine auto            # default: Vision primary, marker fallback
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

Drop a file called `.nomarker` in any directory. parch will skip that directory and its descendants.

### Source files take priority

parch automatically skips PDFs that have a sibling `.tex`, `.md`, `.markdown`, `.typ`, `.rst`, or `.rmd` file with the same name. No point converting a PDF back to markdown when the original source is right there.

## Running as a background service

parch is designed to run periodically via launchd. An example `com.parch.indexer.plist` is included in the repo.

### Install the service

```sh
# Edit the plist to point at your parch binary and set scan roots
# Then install it:
cp com.parch.indexer.plist ~/Library/LaunchAgents/
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

If you have a spare Mac running 24/7, point it at a specific folder for offloaded processing:

```xml
<key>ProgramArguments</key>
<array>
    <string>/path/to/parch</string>
    <string>run</string>
    <string>--root</string>
    <string>/Users/you/Dropbox/ToConvert</string>
</array>

<key>WatchPaths</key>
<array>
    <string>/Users/you/Dropbox/ToConvert</string>
</array>
```

Dropbox placeholder files (Smart Sync "online only") are materialized transparently when parch reads them.

## Data & paths

- **Index database:** `~/.parch/index.db` (SQLite, GRDB-managed migrations)
- **Log file:** `~/.parch/parch.log` (rotated at 5 MB, previous kept at `parch.log.1`)
- **Process lock:** `~/.parch/parch.lock`
- **Output:** Each PDF gets a sibling directory with the same stem, containing `<stem>.md`. E.g. `report.pdf` → `report/report.md`. Duplicates get symlinked to the canonical output directory.
- **Vision quality metadata:** `.vision-quality.json` sidecar inside each Vision-produced output directory

## Troubleshooting

**All files marked failed with "Resource deadlock avoided"**
You're on an older parch build. This was a FileHandle issue on cloud provider files that's fixed in current versions. Rebuild from main.

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
