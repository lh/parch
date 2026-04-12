# Deep Dive: Two-Engine Conversion Architecture

Educational notes on the significant changes in this session: the Vision/Marker two-engine refactor (commit `424d210`), the FileHasher POSIX fix (`c5c007e`), and the ProcessLock addition (`7174b96`). Written to help you understand the *why*, not just the *what*.

---

## 1. The ConversionEngine protocol

**Files:** `Sources/Parch/Converter/ConversionEngine.swift`, `MarkerEngine.swift`, `VisionEngine.swift`, `EngineFactory.swift`

### What it does

Before this change, `Converter` was a concrete class that shelled out to marker via conda. The Orchestrator held a `Converter` and called `converter.convert(pdfPath:)`. One engine, hardcoded.

After this change, `ConversionEngine` is a Swift protocol with one required method (`convert(pdfPath:) throws -> String`) and one required property (`var engine: Engine { get }`). Two types conform to it: `VisionEngine` (Apple's built-in OCR) and `MarkerEngine` (the existing conda-based path). The Orchestrator now holds `ConversionEngine` references — it no longer knows or cares which engine is doing the work.

### Why this approach

The textbook name for this is **Strategy pattern**: you have an algorithm (PDF → markdown) with multiple interchangeable implementations, and you want the caller to pick which one at runtime without knowing the details. Protocols in Swift are how you express this cleanly.

**Alternatives considered:**

- **Keep `Converter` concrete, add a `useVision: Bool` flag.** This is the "just add an if-statement" approach. It's fine for two implementations but rots fast: by the time you have three engines, `Converter` becomes a switch statement full of engine-specific setup, and each engine's logic is tangled with the others' error handling. It also makes testing harder — you can't swap in a fake converter without subclassing.

- **Subclass `Converter` to get `VisionConverter` and `MarkerConverter`.** This works but inheritance for this kind of substitution is overkill. Swift protocols give you the same polymorphism without the baggage of inheritance hierarchies (and without forcing `final` off the base class). The "composition over inheritance" principle applies here: `Orchestrator` doesn't *inherit from* or extend a converter, it *uses* one.

- **A wrapper engine that does the fallback internally.** Tempting — you'd have `AutoEngine` that wraps both and handles the quality check invisibly. Rejected because the Orchestrator owns the per-PDF lifecycle (hashing, dedup, database writes). Putting fallback logic inside a wrapper would mean either duplicating that lifecycle inside the wrapper or losing the ability to record which engine handled each file. Better to let the Orchestrator drive the decision and keep engines ignorant of each other.

**Trade-offs accepted:**

- One level of indirection: `primaryEngine.convert(...)` dispatches through a protocol witness table instead of a direct call. In practice this is a nanosecond per call, irrelevant here.
- Protocols-with-associated-types would let you push more into the type system (e.g., encoding whether an engine has quality metrics), but `ConversionEngine` deliberately stays a plain protocol because simple is better than clever for two implementations.
- The `engine` property on the protocol exists only so the Orchestrator can tell them apart for database tracking. A purer protocol wouldn't need it — but we need it, so there it is. Honest beats pure.

### Key concepts

**Swift protocols as interfaces.**
- **What:** A protocol declares a contract ("any type that conforms to `ConversionEngine` must have these methods and properties"). Any type — struct, class, enum — can conform.
- **Why here:** Two engines with the same contract but wildly different implementations (one shells out to a Python process, the other calls macOS frameworks). Protocol is the minimal abstraction that lets the caller treat them uniformly.
- **When to use:** Whenever you have multiple implementations of "a thing that does X" and callers shouldn't care which implementation they got.
- **Watch out:** Swift protocols have two modes — they can be used as "existential types" (`let engine: ConversionEngine`, dispatch at runtime) or as generic constraints (`func foo<T: ConversionEngine>(_ t: T)`, dispatch at compile time). The existential form is more flexible but slightly slower; the generic form is faster but can't be stored heterogeneously. We use existentials here because the Orchestrator stores one engine and doesn't know its concrete type. That's the right default; only reach for generics when profiling says you need to.

**Sendable conformance.**
- **What:** `Sendable` is a marker protocol that tells the Swift concurrency checker "values of this type can safely cross actor/task boundaries". Classes must be `final` and have only immutable properties (or manage their own synchronisation) to be `Sendable`.
- **Why here:** The Orchestrator spawns conversion tasks in a `TaskGroup`. Each task needs to call `engine.convert(...)`, which means the engine reference crosses into a child task. Swift's concurrency checker will refuse to compile that unless the engine is `Sendable`.
- **When to use:** Any value you pass into `Task { }`, `TaskGroup`, or across an `await`. The compiler will tell you when you need it.
- **Watch out:** Making something `Sendable` is a promise you're keeping, not just a label. If you mark a class `Sendable` but it has mutable state without locks, you've lied to the compiler and you'll get data races in production. For `MarkerEngine` and `VisionEngine`, all stored properties are `let` constants, so there's nothing to race on.

**Protocol Witness Tables.**
- **What:** When you call a method through a protocol reference, Swift looks up the actual implementation via a "witness table" — essentially a dictionary mapping protocol methods to concrete implementations for each conforming type. This is how polymorphism works under the hood.
- **Why here:** Useful background for understanding why protocols cost anything at all. `primaryEngine.convert(...)` isn't a direct jump; it's an indirect call through the witness table.
- **When to use:** N/A — this is a mental model, not something you'd use.
- **Watch out:** People sometimes panic about protocol dispatch performance. For 99% of code it's irrelevant. For inner loops called millions of times per second, benchmark before worrying.

### How it connects

- **Called by:** `Orchestrator.convertWithFallback(path:)` in `Orchestrator.swift`. That's the only consumer.
- **Calls:** `ScanRules.outputDirectory(...)` and `ScanRules.markdownPath(...)` to decide where to write output. Both engines do this, so it's a natural shared responsibility.
- **Breaks if changed:** Changing the protocol signature cascades to both engines and the Orchestrator. Adding a new engine does not break anything — it's purely additive.

### Go deeper

- **Swift protocols — official guide:** https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/ — the Protocols chapter of the Swift book. Read the sections on "Protocols as Types" and "Protocol Composition".
- **Sendable and concurrency checking:** https://developer.apple.com/documentation/swift/sendable — Apple's reference. Short but correct.
- **WWDC 2016 — "Protocol-Oriented Programming in Swift":** https://developer.apple.com/videos/play/wwdc2015/408/ — Dave Abrahams' talk. Old but still the clearest explanation of why Swift leans protocols over inheritance. (Note: 2015 video, still accurate.)

---

## 2. The fallback decision and QualityScore

**Files:** `Sources/Parch/Converter/QualityScore.swift`, `VisionEngine.swift` (sidecar writing), `Orchestrator.swift` (sidecar reading and retry)

### What it does

After Vision converts a PDF, it writes a small JSON file (`.vision-quality.json`) alongside the markdown, containing the average OCR confidence score, total character count, page count, and a "garbled ratio" (the fraction of single-character "words" — a proxy for Vision misreading graphical text as fragmented characters).

When the Orchestrator finishes a Vision conversion, it reads that sidecar and checks `quality.isAcceptable`. If quality is poor *and* a fallback engine is available, it deletes the Vision output and retries with marker. If quality is fine, it keeps the Vision output and records `engine: .vision` in the database.

### Why this approach

The interesting design decision isn't "use quality thresholds to decide fallback" — that's obvious once you admit Vision has failure modes. The interesting decision is **how** the quality signal crosses from the engine to the Orchestrator.

**Alternatives considered:**

- **Add `quality` as a return value of `convert()`.** The protocol's `convert` method would return `(outputDir: String, quality: QualityScore?)` instead of just `String`. Rejected because MarkerEngine has no quality signal to report — the protocol would be littered with options specific to one engine. Strategy pattern works best when all implementations produce the same shape.

- **Use a protocol extension with an optional `qualityReport` method.** More Swift-idiomatic but still leaks Vision-specific concerns into the protocol. Also makes testing weirder (a conforming type that returns nil is correct but awkward).

- **Sidecar file as a contract.** Vision writes a side file; Orchestrator reads it if present. Engines that don't write one are simply skipped in the quality check. The protocol stays clean. Rejected by some because "it's just a file, not a type-safe signal" — but that's actually a feature. It keeps the engines decoupled, and if you ever want to inspect Vision's quality scores from the command line without running the Swift code, you can just `cat .vision-quality.json`.

**Trade-offs accepted:**

- Sidecar files are a side-channel between Vision and the Orchestrator. If someone deletes it manually, the Orchestrator silently stops caring about quality for that file. That's fine — worst case is a low-quality file sticks around instead of being retried.
- The sidecar path is a string append, not type-checked. A rename of `.vision-quality.json` in one file but not the other would silently break the fallback. Mitigated by the fact that both sides of the contract are literally five lines of code and sit in the same folder. For a bigger surface area, you'd introduce a shared constant.
- JSON serialization is overkill for four fields. `Codable` makes it cheap, though, and the file is human-readable for debugging, which has already paid off when tuning thresholds.

### Key concepts

**Side-channel communication via files.**
- **What:** Two components communicate not by passing data through method calls but by one writing a file and the other reading it later.
- **Why here:** Keeps the engines from needing to know about each other or about the Orchestrator's quality-check logic. The sidecar is a stable artefact: it persists beyond the run, can be inspected, can be deleted to force a re-check.
- **When to use:** When two components should stay decoupled, when the signal should outlive the process, or when you want the signal to be inspectable by other tools (grep, cat, editor).
- **Watch out:** Side-channels are implicit contracts. Unlike type-checked method signatures, a file contract can rot silently — a rename, a path change, a schema shift — without the compiler noticing. Use when the benefit of decoupling outweighs the cost of the implicit coupling. For a large system, prefer explicit interfaces.

**Confidence scores and quality heuristics.**
- **What:** `VNRecognizeTextRequest` returns per-observation confidence scores in `[0, 1]`. Higher means "Vision is more sure this text is right". We average these and combine with structural checks (characters per page, garbled-word ratio).
- **Why here:** A single metric isn't enough. Vision can be 0.97 confident about each individual fragment while producing garbled output overall, because it's confident about tiny wrong pieces. Combining multiple heuristics catches different failure modes: confidence catches illegible text, character count catches "Vision produced almost nothing", garbled ratio catches "Vision read slide graphics character-by-character".
- **When to use:** Any time you have an ML output with a confidence score, you should assume the confidence is correlated with quality but not equal to it. Real-world confidence calibration is hard; ensembling multiple heuristics is usually the practical answer.
- **Watch out:** Thresholds are data-dependent. The current 0.5 / 0.3 / 100 values are starting points from a tiny benchmark (four documents). In production you'd want to tune them against a larger corpus, ideally with human-rated ground truth. Also: sophisticated failure modes can beat simple heuristics. If you started OCRing handwritten letters you'd probably need different checks entirely.

**Codable for simple serialization.**
- **What:** Swift's `Codable` protocol lets any struct with compatible property types be encoded to and decoded from JSON (or other formats) via `JSONEncoder`/`JSONDecoder`.
- **Why here:** `QualityScore` is four primitive fields. `Codable` makes the JSON trip a two-line affair with zero boilerplate.
- **When to use:** Any time you need to persist or exchange simple data structures. Default choice for config files, API payloads, sidecar metadata.
- **Watch out:** Evolving the schema over time is your responsibility — adding a field is fine (make it optional), removing one silently drops data from new versions reading old files. For long-lived schemas, consider versioning the file format.

### How it connects

- `VisionEngine.convert(...)` writes the sidecar at the end of a successful conversion.
- `Orchestrator.convertWithFallback(...)` reads the sidecar when the primary engine is Vision, checks `isAcceptable`, and either keeps the output or retries with the fallback engine.
- If you change where the sidecar lives or what it's called, update both sides. There's no single constant for it — that's the main weakness of the sidecar approach.
- If you rename any of the threshold constants in `QualityScore`, nothing downstream breaks because all the logic is encapsulated in `isAcceptable`.

### Go deeper

- **Vision framework — text recognition:** https://developer.apple.com/documentation/vision/recognizing_text_in_images — Apple's official walkthrough of `VNRecognizeTextRequest`, including recognition levels and language hints.
- **Codable in Swift:** https://developer.apple.com/documentation/foundation/archives_and_serialization/encoding_and_decoding_custom_types — official docs on Codable, JSONEncoder, and common pitfalls.
- **"Confidence is not calibration" — general ML reading:** Guo et al., *On Calibration of Modern Neural Networks* (2017), https://arxiv.org/abs/1706.04599. The accessible takeaway: modern neural networks tend to be overconfident, which is exactly why a 0.97 confidence can coexist with garbled output.

---

## 3. POSIX read() vs Foundation FileHandle

**File:** `Sources/Parch/Scanner/FileHasher.swift` (commit `c5c007e`)

### What it does

The hash function used to call `handle.readData(ofLength:)` on a `FileHandle`. On certain Dropbox files, that call threw an Objective-C exception that Swift could not catch, terminating the process. The fix replaces the FileHandle path entirely with POSIX `open()` / `read()` / `close()` syscalls using raw C APIs.

### Why this approach

This is one of those fixes where the answer is "don't use the shiny abstraction". FileHandle is a Foundation class — it inherits behaviour from NSFileHandle, and NSFileHandle's `readData(ofLength:)` throws *Objective-C exceptions* (NSException), not Swift errors, when the underlying syscall fails in certain ways. Swift's `do/catch` only catches types conforming to `Error`. NSException is not an `Error`. It bypasses Swift error handling and terminates the process with an uncaught exception.

The correct options, in decreasing order of "Swift-native":

1. **`FileHandle.read(upToCount:)` (the newer Swift-throwing API).** This was my first fix. It does throw proper Swift errors for most failures — but not all. On the particular EDEADLK error Dropbox's file provider was returning, `read(upToCount:)` still blew up with an NSException in our testing. The "Swift-throwing" API apparently doesn't cover every path the underlying Objective-C code can take.

2. **POSIX `open` / `read` / `close`.** These are C functions, not Swift, and they report errors via return codes (`-1` with `errno`), not exceptions. There is no uncatchable failure mode. The fix converts errno into a Swift `POSIXError` so the rest of the code catches it normally.

**Trade-offs accepted:**

- You lose some Foundation niceties: no automatic Data objects, you have to manage a raw pointer and a buffer size yourself, and you have to remember to `close(fd)` (we use `defer`).
- You gain reliability. Every error path is expressible as a Swift throw. The crash loop disappears.
- Slight verbosity — about 10 more lines of code than the FileHandle version. Worth it.

**A lesson worth internalising.** Foundation APIs that were bridged from Objective-C in the early Swift days often have hidden NSException paths. The Swift team has been slowly replacing them with Swift-throwing variants, but coverage is incomplete. When you hit an uncatchable failure in code that looks like it should be catchable, suspect Foundation's Objective-C heritage and look for a lower-level alternative.

### Key concepts

**Objective-C exceptions vs Swift errors.**
- **What:** Obj-C has `@throw` / `@try` / `@catch`, used for truly exceptional cases (programmer errors in most Apple frameworks). Swift has `throw` / `do/catch`, used for recoverable errors. The two systems are *not* interoperable: Swift's `do/catch` cannot catch an NSException, and the only way to catch one from Swift is to bridge through Objective-C code.
- **Why here:** NSFileHandle's `readData(ofLength:)` raises NSExceptions for I/O failures. This is considered a quirk of the API's age (the method predates Swift error handling).
- **When to watch out:** Any time you're calling a Foundation API that was around before Swift (anything with `NS` prefix in its history). If it can fail at runtime with data you don't control, read the documentation carefully and prefer the Swift-throwing alternative if one exists.
- **Workaround if you *must* catch NSException:** You can't from pure Swift. You'd write a tiny Objective-C helper that wraps the call in `@try/@catch` and returns an error to Swift.

**POSIX file I/O (`open`, `read`, `close`, `errno`).**
- **What:** The low-level filesystem API provided by every Unix-like OS. `open` returns a file descriptor (a small integer) or `-1` on failure; `read` returns the number of bytes read, `0` at EOF, or `-1` on failure; `close` releases the descriptor. Failures set the global `errno` variable, whose values are defined by POSIX (`EBADF`, `ENOENT`, `EDEADLK`, etc.).
- **Why here:** No hidden exception paths. No framework magic. Whatever the kernel tells us, we get, and we can handle it with a Swift `throw`.
- **When to use:** For simple stream reading of files, POSIX is often cleaner than Foundation, particularly when failures must be handled programmatically rather than ignored. Also useful when you need control over flags (`O_NONBLOCK`, `O_DIRECT`, etc.) that Foundation doesn't expose.
- **Watch out:** You're responsible for closing the descriptor (leak otherwise). You're responsible for allocating and freeing any buffers. And you need to handle short reads (`read` may return less than you asked for) — our loop does this correctly by looping until read returns 0 or throws.

**`defer` in Swift.**
- **What:** A `defer { ... }` block runs when the enclosing scope exits, no matter how it exits (normal return, thrown error, early return). Functionally equivalent to RAII in C++ or `finally` in Java, but tied to the scope rather than the object.
- **Why here:** We need `close(fd)` to run even if `read()` throws. `defer { close(fd) }` is the idiomatic way.
- **When to use:** Anywhere you acquire a resource that must be released. Think of it as "the cleanup goes right next to the acquisition".
- **Watch out:** Multiple defers run in LIFO order (last-in, first-out) within a scope. And `defer` is tied to *scope*, not *object* — if you pass the resource out of the scope, the defer still fires.

### How it connects

- **Called by:** `Orchestrator.processSingle(...)` in `Orchestrator.swift`, which hashes every PDF before considering dedup or conversion.
- **Reads:** The raw bytes of the file, streamed 1 MB at a time.
- **Returns:** A lowercase hex SHA-256 string, stored in the `content_hash` column.
- **Breaks if changed:** Dedup. Every duplicate PDF relies on SHA-256 being stable. If you change the hash algorithm or normalisation, all existing `content_hash` entries are wrong and dedup breaks until the index is rebuilt. Don't change the algorithm without a migration.

### Go deeper

- **POSIX read(2) man page:** `man 2 read` on your machine, or https://pubs.opengroup.org/onlinepubs/9699919799/functions/read.html — the canonical description, including the definition of short reads and error semantics.
- **Why NSExceptions and Swift errors don't mix:** https://forums.swift.org/t/objective-c-exceptions-in-swift/38118 — a Swift Forums thread explaining the design decision and workarounds. Short, accurate.
- **"Using Imported C APIs from Swift":** https://developer.apple.com/documentation/swift/using-imported-c-apis — Apple's guide to calling C functions from Swift, including how `errno` is exposed.
- **Swift `defer`:** https://docs.swift.org/swift-book/documentation/the-swift-programming-language/statements/#Defer-Statement — one paragraph in the Swift language reference, worth reading in full.

---

## 4. Process lock via flock()

**File:** `Sources/Parch/ProcessLock.swift` (commit `7174b96`)

### What it does

Before every parch invocation does real work, it tries to acquire an exclusive non-blocking POSIX file lock on `~/.parch/parch.lock`. If the lock is taken by another parch process, the new invocation exits immediately. If the lock is free, the new invocation holds it for its lifetime and releases it via `deinit`.

This stops the scenario we hit on Devon: launchd fires parch every hour via `StartInterval`, but a given conversion run takes longer than an hour, so the next launchd fire overlaps with the previous run, and two marker processes end up competing for the GPU on the same file.

### Why this approach

**Alternatives considered:**

- **PID file.** Write `getpid()` to a file on start; on start, read the file and check if a process with that PID exists. Classic Unix pattern. Rejected because it's racy (two processes can read the file at the same instant and both think they're alone), because it's brittle (PID reuse after a crash leaves a stale file that a new unrelated process might match), and because the atomic `flock` is strictly better on any OS we care about.

- **`KeepAlive` in launchd instead of `StartInterval`.** You'd have launchd run parch continuously, restarting it on exit. That sidesteps the overlap problem because there's only ever one instance. But it also means parch has to be a long-running daemon, which changes the architecture significantly — you'd need internal scheduling, long-lived database connections, and hot-reload logic for config. Too much change for a small problem.

- **Checking the database for a "running" row.** Add an `indexed_pdf.status = 'in_progress'` row or a separate `runs` table. Works but doesn't handle crashes gracefully (the row stays "in progress" forever) and couples "am I running?" to the database being writable.

- **`flock()` on a lock file.** Cheap, atomic, kernel-enforced, survives crashes cleanly (when the process dies, the OS releases the lock). One system call to acquire, one to release. It's the right answer.

**Trade-offs accepted:**

- The lock is per-user, not system-wide. Two different users running parch on the same machine would not interfere with each other — which is usually what you want, but worth knowing.
- The lock doesn't encode *who* holds it. If you want to know "which PID is currently running parch", you can't tell from the lock alone. You could add a PID write to the lock file for diagnostics.
- If the lock file gets deleted while held, things get weird. We don't defend against that because it would require the user to manually `rm ~/.parch/parch.lock`, which is clearly "you're holding it wrong" territory.

### Key concepts

**flock(2): advisory vs mandatory locks.**
- **What:** `flock` is a POSIX advisory locking syscall. "Advisory" means the lock only affects processes that *also* call `flock` on the same file — nothing stops a rogue process from just opening and reading the file. But every parch process calls `flock`, so cooperation is guaranteed in our use case.
- **Why here:** All we need is "if another parch is running, back off". Advisory is sufficient, and advisory locks are universally supported (mandatory locks exist on Linux but are deprecated and unsupported on macOS).
- **When to use:** Any time one process needs to coordinate with itself — or a small number of cooperating processes — around a shared resource. Backups, batch jobs, singleton daemons.
- **Watch out:** "Advisory" catches people out. A lock that locks nothing is useless if you're trying to prevent a malicious process from interfering. For cooperative use it's fine and it's what everyone actually uses.

**`LOCK_EX | LOCK_NB` — blocking vs non-blocking.**
- **What:** `LOCK_EX` asks for an exclusive lock (no other holder). `LOCK_NB` says "return immediately if you can't get it" rather than blocking until it's free. Without `LOCK_NB`, a second parch process would sit there waiting for the first to finish, then start running — potentially launching a conversion hours later when it was supposed to run at a specific time.
- **Why here:** We *want* the second invocation to exit, not wait. Waiting would make the hourly schedule nonsense.
- **When to use:** Non-blocking for "don't duplicate work" patterns. Blocking for "serialize access to a shared resource".
- **Watch out:** Forgetting `LOCK_NB` and wondering why your program hangs.

**Using `deinit` for cleanup.**
- **What:** Swift classes have a `deinit` block that runs when the last reference drops. For resources tied to the lifetime of an object, `deinit` is the right place to release them.
- **Why here:** `ProcessLock` is a class holding a file descriptor. When the function that acquired it returns, the lock should be released. Tying release to `deinit` guarantees cleanup regardless of how the function exits (normal return, thrown error, runtime trap).
- **When to use:** Any class that owns a resource (file descriptor, socket, native pointer, memory buffer). Pair acquisition in `init` with release in `deinit`.
- **Watch out:** `deinit` only runs for classes, not structs. And if you accidentally create a reference cycle, `deinit` never runs at all. The `ProcessLock` here is fine because the caller binds it to a local variable (`let lock = ProcessLock.acquire()`) that goes out of scope at function end.

### How it connects

- **Called by:** `RunCommand.run()` and `ConvertCommand.run()`, before any database or conversion work.
- **If acquisition fails:** The command logs a message and returns normally (exit 0). This is deliberate — it means launchd sees a successful exit even for overlapping invocations, so it doesn't count them as failures.
- **Breaks if changed:** If you changed the lock file path, parallel invocations from an old binary and a new binary could coexist and trample each other. Unlikely in practice because both machines run the same build.

### Go deeper

- **flock(2) man page:** `man 2 flock` or https://man7.org/linux/man-pages/man2/flock.2.html — the canonical reference. Linux man page but macOS flock behaves identically for our purposes.
- **"Locking files in POSIX":** https://gavv.net/articles/file-locks/ — a thorough comparison of `flock`, `fcntl`, and `lockf`, including their interaction and when each is appropriate. Good if you're curious why there are three similar APIs.
- **Apple docs on class lifecycle:** https://docs.swift.org/swift-book/documentation/the-swift-programming-language/deinitialization/ — the Swift book's one-page chapter on `deinit`. Short and clear.

---

## Patterns worth noticing across the session

A few meta-observations about the engineering style we used this session, which are general lessons:

1. **When you hit an uncatchable failure, look for the lower-level API.** The FileHasher fix wasn't about being clever — it was about retreating to a layer with fewer hidden behaviours. Foundation's convenience often comes with Objective-C era baggage. POSIX is boring and works.

2. **Decouple via files when it keeps interfaces clean.** The `.vision-quality.json` sidecar is an informal contract, but it let the protocol stay minimal. For a two-engine system this is right. For a twenty-engine system you'd formalise it into a proper interface.

3. **Advisory locks solve 90% of "don't run twice" problems.** The fancy answer (database rows, coordinator processes, message queues) is almost never needed for a single-machine background job. `flock` plus exit-on-conflict is enough.

4. **Protocols as interfaces, not ceremonies.** `ConversionEngine` has one method and one property. It doesn't need more. A protocol isn't a design document — it's the minimum contract required for callers to ignore implementation details. Keep it small.

5. **The Strategy pattern is underused and overnamed.** Most developers recognise it in textbooks but avoid introducing it in real code because it "feels like over-engineering". For two implementations of a thing where you want to swap at runtime, it's exactly right and costs almost nothing in Swift.

---

*Generated 2026-04-12. See git log commits `424d210`, `c5c007e`, `7174b96` for the changes discussed.*
