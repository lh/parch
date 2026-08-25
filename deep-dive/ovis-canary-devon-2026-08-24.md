# Ovis engine canary on real scanned documents (Devon, 2026-08-24)

Nine PDFs from Devon's watch folder, copied to a staging directory and
converted with `parch convert-file --engine ovis` through the real engine
path (background priority, shared index, `ovis-engine` branch built in a
separate checkout). Devon is a Mac Mini M1 with 8 GB RAM; the model ran on
MPS. Sample: seven scanned documents spanning content types, two digital
controls. Documents are described generically here; several contain
patient-identifiable data and stay on the machine.

## Timings (wall clock per document, background priority)

| Document | Pages | Elapsed | s/page |
|---|---|---|---|
| Typewriter-style list (scan) | 1 | 117s | 117 |
| OCT-angiography export (pure images, no text) | 2 | 2652s | 1326 |
| Device biometry export (scan) | 2 | 554s | 277 |
| Digital one-pager (control) | 1 | 185s | 185 |
| Employment contract (office scan) | 19 | 1617s | 85 |
| Digital table document (control) | 2 | 250s | 125 |
| Scanned device-screen note | 2 | 268s | 134 |
| Dense device measurement export (scan) | 4 | 3147s | 787 |
| Signed office document (scan) | 6 | 805s | 134 |

All nine exited 0 and produced markdown. Healthy pages run 85-280s on the
M1 at background priority (the same worker does 12-19s/page unniced on an
M3 Max). The two outliers are pages that generate enormous token counts:
pure-image pages grind toward the 16k token cap before post-processing
strips the output down.

## Quality

**Scanned text documents: ovis is dramatically better than Vision.** On a
scanned device screen full of clinical measurements, ovis reproduced every
label-value pair on page 1 exactly - values, units, angles, Greek letters
as LaTeX - with one wrong label on page 2 ("ACE" for "ACD"). Vision's
production output for the same page scattered labels and values into
separate line runs (a reader must re-associate them by position) and
mangled units ("9pm" for 9um, "AK" for delta-K). For LLM consumption of
numeric content, Vision's output is actively dangerous; ovis's is
faithful. The 19-page contract scan and 6-page signed document read
cleanly throughout. Digital controls regressed nothing (correct HTML
tables, correct text).

**Pure-image pages: ovis fabricates.** The OCT export contains no text at
all; ovis output "The quick brown fox jumps over the lazy dog." - filler
text presented as page content, and the conversion was recorded
`complete|ovis` in the index. Production had correctly failed this file
("Image-only PDF, no extractable text"). A fabricated document entering
the index is worse than a failed conversion.

## Consequences for auto-mode routing

- **Refuted:** "route image-only PDFs (Vision OCR finds ~0 chars) to ovis
  as a rescue." True image-only documents have nothing to transcribe;
  ovis invents text instead of failing. Keep the current behaviour:
  Vision-OCR-empty documents stay failed.
- **Supported:** "route scanned text documents (no text layer, Vision OCR
  finds text but quality is poor) to ovis instead of marker." This is the
  class where ovis matched or beat marker's structure at a third of
  marker's OCR wall time in the laptop benchmark, and beat Vision badly
  here on faithfulness.
- **Unchanged:** digital PDFs keep Vision primary with marker fallback;
  marker reads the text layer and is faster and character-exact there.
- **Integration tweak worth considering:** cap the worker's
  `max_new_tokens` below 16384 (dense real pages generated ~1-3k tokens;
  8192 would halve the worst-case runaway cost, ~22 min/page on an M1).

## Environment notes

- The `ovis` conda env, model weights, canary checkout
  (`~/Code/OCR/parch-ovis-canary`), staged copies and their outputs
  (`~/parch-ovis-canary-data/`) remain on Devon for inspection. Canary
  rows were removed from the production index.
- Four historical "Hash failed: resource deadlock" failures were Dropbox
  placeholder files (no local blocks); one has since materialised and
  reads fine. A rescan after the service is fixed should retry them.
