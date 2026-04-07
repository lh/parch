# Session Handoff - 2026-04-07

## Completed

### Tool Evaluation
- Installed and compared **Marker** (datalab-to/marker) and **MinerU** (opendatalab/MinerU) for PDF-to-markdown conversion
- Ran both on "Attention Is All You Need" paper, performed semantic diff (77.6% similarity, mostly formatting differences)
- **Marker chosen** for LLM-readable output: cleaner markdown tables, readable LaTeX, preserved footnotes, smaller output
- MinerU retained in conda env `mineru` for potential use in scanned forms/demographic extraction project

### Parch Application (Layers 1-3)
- Created GitHub repo: https://github.com/lh/parch (private)
- Swift Package with GRDB, swift-argument-parser, swift-log
- **SQLite index** at `~/.parch/index.db` with schema for tracking PDFs (content_hash, file_path, file_size, mtime, conversion_status, canonical_path)
- **Scanner**: mdfind fast pass + FileManager directory walk. First scan found **61,678 PDFs** in ~3 minutes
- **ScanRules**: skip logic for system dirs, app bundles, .Trash, node_modules, etc. Supports `.nomarker` sentinel files
- **CLI**: `parch run`, `parch status`, `parch list-pending`, `parch list-failed`, `parch convert`
- All 11 unit tests passing

### Parch Converter (Layers 4-5) - Partially Complete
- **Converter.swift**: Process wrapper around `marker_single` via `nice -n 20`
- **Orchestrator.swift**: TaskGroup-based worker pool with thermal state checks, SHA-256 dedup, symlink creation for duplicates
- **ConvertCommand.swift**: `parch convert --limit N --workers N`
- Successfully converted 3 PDFs end-to-end (scan → hash → convert → update index)

## Known Issues / Blockers

### Critical: MPS/Metal acceleration broken in uv-installed Marker
- `uv tool install marker-pdf` installs marker at `~/.local/bin/marker_single`
- surya-ocr hits `torch.AcceleratorError: index out of bounds` on MPS device
- **CPU fallback works** but is ~200x slower (56 min vs ~15 sec per PDF)
- **Conda env `marker` works fine with MPS** - same torch 2.11.0, same surya-ocr 0.17.1
- Root cause not yet identified - session ended during investigation
- The converter currently forces `TORCH_DEVICE=cpu` as a workaround

### Minor
- MinerU debug PDFs (`_origin.pdf`, `_layout.pdf`, `_span.pdf`) get indexed - should skip or `.nomarker` the output dir
- Scan roots overlap: `~/` encompasses `~/Library/CloudStorage` and `~/Library/Mobile Documents`, causing the walk phase to re-traverse cloud dirs already covered by mdfind

## Current State of Files

```
parch/
├── Package.swift                          # swift-tools-version: 6.2, macOS 15+
├── Sources/Parch/
│   ├── Parch.swift                        # @main, subcommands registered
│   ├── Commands/
│   │   ├── StatusCommand.swift
│   │   ├── ListPendingCommand.swift
│   │   ├── ListFailedCommand.swift
│   │   ├── RunCommand.swift               # scan + convert
│   │   └── ConvertCommand.swift           # convert only
│   ├── Database/
│   │   ├── ParchDatabase.swift            # DatabaseQueue wrapper, CRUD
│   │   ├── Migrations.swift               # v1 schema
│   │   └── IndexedPDF.swift               # GRDB record with CodingKeys
│   ├── Scanner/
│   │   ├── Scanner.swift                  # mdfind + walk
│   │   ├── ScanRules.swift                # skip/include logic, .nomarker
│   │   └── FileHasher.swift               # SHA-256 chunked
│   └── Converter/
│       ├── Converter.swift                # marker_single Process wrapper
│       └── Orchestrator.swift             # worker pool, dedup, thermal checks
└── Tests/ParchTests/
    └── ScanRulesTests.swift               # 11 tests
```

Database at `~/.parch/index.db` has 61,678 PDFs indexed, 3 complete, rest pending.

## Next Steps

1. **Fix MPS acceleration** - Investigate why conda env works with MPS but uv tool install doesn't. Options: (a) point parch at `conda run -n marker marker_single` as quick fix, (b) pin surya-ocr/torch versions in uv install, (c) diff the two environments to find the actual difference. This is the blocker - without MPS, converting 61k PDFs would take years.

2. **Test dedup flow** - Run convert on PDFs that exist in multiple locations to verify SHA-256 dedup and symlink creation works end-to-end.

3. **Layer 6: launchd service** - Create `com.parch.indexer` plist for persistent background execution with `NSBackgroundActivityScheduler`, battery awareness, and proper QoS scheduling. This is the "runs quietly forever" piece.
