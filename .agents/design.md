# Design decisions

The architecture this package actually implements is described in `CLAUDE.md`; the staged plan,
the per-stage findings and the 0.2 feature gap are in [roadmap.md](roadmap.md); vendoring and the
patch series are in [vendoring.md](vendoring.md). Those three, plus the code and the man pages,
are authoritative for anything that shipped.

What survives here is the part none of them carry: **why each API question was answered the way it
was**, including the ones still open. [roadmap.md](roadmap.md) has the one-line resolutions in its
*Open questions* table and links back here for the reasoning.

The rest of this file — the original ~1300-line specification, written before Stage 0 — was
removed once Stages 0–9 shipped and the code became the better description of itself. It is in
the git history if a decision ever needs re-litigating.

## The decisions

Four remain genuinely open — serialization, the cursor API, environment resizing, and the on-disk
layout beyond the `subdir` default. None should be settled unilaterally.

### R object model — **settled in Stage 2**

**Plain external pointer plus S3.** The `mdbx_env` object is the `EXTPTRSXP` itself, carrying its
`class` and its opening parameters (`path`, `readonly`, `subdir`) as attributes. No list wrapper,
no environment-backed object, no R6.

Both class and attributes are attached natively in `new_env_sexp()`, not from R. Modifying an
external pointer from R can duplicate the SEXP, and `duplicate()` copies the address without the
finalizer -- which is registered against the original. Were only the copy to stay reachable, the
original would be collected and would close the environment out from under it. R therefore only
ever reads these attributes.

Transactions and cursors should follow the same shape, adding parent retention through the
protected field as described under *Ownership and Lifetime*.

Two extensions to this were considered after Stage 4 and **declined**, so that there stays exactly
one way to do each thing:

- **`txn$get()` / `txn$put()` method syntax.** Technically available — `$` does dispatch on a
  classed external pointer once an S3 `$` method exists, verified — but it is sugar that duplicates
  every function under a second name.
- **Environment-level data operations**, i.e. `mdbx_get(env, key)` opening and committing its own
  transaction. The reference binding offers this (`env.get(key, db=None, default=None)`) and it is
  ergonomic for a single operation, but it would make the transaction invisible in exactly the
  cases where it matters, and it cannot compose: an environment permits one transaction at a time,
  so it would fail whenever the caller already holds one.

The transaction stays explicit. It is what buys atomicity across operations, a consistent read
snapshot, and throughput — measured at 1000 keys, one transaction versus one per operation: 0.026 s
against 0.893 s for writes (34x), 0.006 s against 0.011 s for reads.

### On-disk layout

`mdbx_env_open()` takes `subdir`, defaulting to `FALSE`, which passes `MDBX_NOSUBDIR`: the path is
the data file, and the lock file is that path with `-lck` appended. `subdir = TRUE` gets MDBX's
native layout, a directory holding `mdbx.dat` and `mdbx.lck`.

The default departs from MDBX's own, which is the directory form, because a path like
`cache.mdbx` reads as a filename to an R user and this design's own examples are written that
way. The flag applies only when creating; opening an existing environment detects the layout.

### Missing-key semantics — **settled in Stage 4**

`mdbx_get()` returns `NULL` for a key that is not present, and takes a `default` argument to
override that. `MDBX_NOTFOUND` is an expected outcome, not a condition.

This stays unambiguous because a *stored* zero-length value comes back as `raw(0)`, which is not
`NULL` — absence and emptiness remain distinguishable.

The same principle covers the other two: `mdbx_put(overwrite = FALSE)` returns `FALSE` on
`MDBX_KEYEXIST` rather than raising, and `mdbx_del()` returns whether a record existed. The
reference binding does the same — "put returns False for NOOVERWRITE/NODUPDATA conflicts and
otherwise True", "delete returns whether a record existed".

### Key encoding — **settled in Stage 4: raw, or a single string encoded UTF-8**

Keys and values accept a `raw` vector, or a length-1 character vector which is stored as its UTF-8
bytes. `"k"` and `charToRaw("k")` are therefore the same key. Everything else is rejected.

This was first settled as raw-only, following `clibmdbx` ("All keys and values accept `bytes` or a
contiguous bytes-like object", no `str` encoding). That was revised once written out: `b"key"` is
barely more than `"key"` in Python, but `charToRaw("key")` at every call site is genuinely bad R,
and the noise dominated the README. Accepting strings is the deliberate divergence from the
reference binding.

Two consequences, both documented rather than papered over:

- **Strings are normalized with `enc2utf8()` before `charToRaw()`.** Without it the bytes depend on
  the string's `Encoding()` flag and the session locale — `"café"` is `63 61 66 e9` as latin1 and
  `63 61 66 c3 a9` as UTF-8 — so the same text would be a different key on different platforms.
  This is a correctness requirement, not a nicety.
- **Reads decode to text by default**, via `mdbx_get(as = c("character", "raw"))`. Writing a string
  and reading back a `raw` vector was the asymmetry users hit first, so the inverse of the write
  side is the default. MDBX records no type, so this is an *assumption*: `as = "raw"` is required
  for anything that is not text, including `serialize()` output.

  It is safe to assume because it cannot be wrong quietly. Decoding checks for NUL bytes and
  validates UTF-8, and raises an error naming `as = "raw"` if either fails — and `serialize()`
  output always contains NUL. The alternative of sniffing the bytes and returning character or raw
  was rejected: it makes the return type unpredictable, and a binary value that happens to be valid
  UTF-8 would be silently misread.

  The decode marks `Encoding() <- "UTF-8"`, the read-side half of `enc2utf8()` on write. Without it
  `rawToChar()` returns a string flagged as the native encoding, and non-ASCII text would come back
  wrong on a non-UTF-8 locale.

Only a `raw` key can contain a NUL byte, since R strings cannot. Serialization of arbitrary R
objects remains out of the engine layer.

### Serialization

Determine whether serialization belongs:

- in this package;
- in an optional higher-level layer;
- behind user-selectable codecs.

### Cursor API

Decide how much of the low-level MDBX cursor API should be exposed directly versus wrapped into
R-friendly iterators or chunked scans.

### Database handles — **settled in Stage 8**

**A lightweight R object holding the database's name; the `MDBX_dbi` is resolved per
transaction and never cached across one.** No external pointer, no finalizer, no close.

Of the options considered — external pointer with a finalizer, a bare integer, or a lightweight R
object holding the name — the last was chosen, after
probing libmdbx's actual DBI semantics rather than from the shape of the C API. What the probe
established (`tools/`-style C harness against the vendored amalgamation):

| Question | Answer |
| --- | --- |
| Open a missing name without `MDBX_CREATE` | `MDBX_NOTFOUND` |
| Open the same name twice in one txn | idempotent, same `MDBX_dbi` |
| Creating txn **aborts**, then reuse the dbi | **`MDBX_BAD_DBI`** — the handle is poisoned |
| ...and the database itself | does not exist (`MDBX_NOTFOUND`) |
| Creating txn commits, use dbi in a later txn | valid; `MDBX_dbi` is environment-scoped |
| `max_db = 16` | 15 named databases, then `MDBX_DBS_FULL` |

The third row is why an `MDBX_dbi` must not be cached in an R object: a handle obtained inside a
transaction that later aborts is invalid, and an R object holding the integer would hand it to the
next call. Storing the *name* and re-resolving makes that impossible — after an abort the next
`mdbx_dbi_open()` simply reports `MDBX_NOTFOUND`, which is the truth.

Re-resolving is cheap because it is idempotent within a transaction, and it is cached in
`txn_handle` exactly as the unnamed main database already is — a cache whose lifetime is the
transaction's, so it cannot outlive its own validity.

The decisive advantage is what it removes. `mdbx_dbi_close()` carries an explicit caveat — handles
"should only be closed if no other threads are going to reference them", and never "with any
transactions using the closing dbi-handle". By never opening that door, the whole class of
use-after-close bugs is unreachable: handles are released when the environment closes.
`clibmdbx` exposes `Database.close()` and inherits the hazard; this package does not need to.

The cost is that a DBI slot stays used until the environment closes, bounded by `max_dbs` — which
is already an `mdbx_env_open()` argument, and until now had nothing to spend itself on.

### Environment resizing

MDBX has mechanisms related to map sizing and geometry.

The package should determine how much of this should be automatic versus explicitly configured.

### Durability options — **settled in Stage 5.6**

**Flag pass-through, spelled as names.** `mdbx_env_open(flags = )` and `mdbx_txn_begin(flags = )`
take a character vector of libmdbx's own flag names with the `MDBX_` prefix dropped:
`flags = c("SAFE_NOSYNC", "WRITEMAP")`. `mdbx_env_get_flags()`, `mdbx_env_set_flags()`,
`mdbx_env_sync()` and `mdbx_flags()` complete the surface. Nothing is set by default, so every
commit stays fully durable unless asked otherwise.

This follows the reference binding. `clibmdbx` exposes `flags` as a raw `int` bitmask on
`Environment.__init__`, exports every `MDBX_*` constant, and gives named keyword arguments to
exactly two flags — `readonly` and `subdir`, OR'ed in at `_core.c:994-997`. It makes no exception
for durability, and its safety story lives in `PRODUCTION_OPERATIONS.md` rather than in the API.
`wtdcode/mdbx-py` is more literal still, transliterating the whole enum with upstream's doxygen.

Two deviations from that model, both because R is not Python:

- **Names, not a bitmask.** R has no comfortable idiom for `int` flags — `bitwOr()` at every call
  site — while a character vector of option names is ordinary. The vocabulary lives in
  `src/r_flags.cpp` so the bits come from the vendored `mdbx.h` and cannot drift from it; R
  validates against the same table via `mdbx_flags()`.
- **`RDONLY`, `NOSUBDIR` and `NOSTICKYTHREADS` are reported but not settable.** The first two are
  already `readonly` and `subdir`, so accepting them too would give two ways to say one thing; each
  is rejected with a message naming the argument to use instead. `NOSTICKYTHREADS` is never set
  because it lifts the one-transaction-per-thread rule the live-transaction registry, the finalizer
  ordering and `mdbx_txn_begin()`'s refusal to open a second transaction all depend on.

**A curated `durability = c("durable", "nometasync", "nosync")` enum was considered and rejected.**
It would have made `MDBX_UTTERLY_NOSYNC` — the only mode that can corrupt rather than roll back —
unreachable. Against that: it cannot express `WRITEMAP`, which is orthogonal to durability but
interacts with it, nor any other flag, so it invites a named argument per flag; and `flags` added
later beside it would leave two overlapping ways to set the same bits. Its safety advantage is also
narrower than it looks, since under pass-through every flag must still be named explicitly —
nothing degrades by accident.

Measured on the vendored amalgamation (v0.14.3, macOS, 2000 transactions x 1 put vs 1 transaction x
200000 puts), which is what sized this decision:

| Mode | small transactions | one large transaction |
| --- | --- | --- |
| `SYNC_DURABLE` (default) | 288 txn/s | 1 563 416 put/s |
| `NOMETASYNC` | 10 307 txn/s (35.8x) | -- |
| `SAFE_NOSYNC` | 25 766 txn/s (89.4x) | 1 668 085 put/s (1.1x) |
| `UTTERLY_NOSYNC` | 76 391 txn/s (265.1x) | -- |

The cost is per-*commit*, not per-write. Batching into fewer transactions recovers nearly all of it
at no risk, and the documentation says so wherever the flags are described.

Also measured, and not documented upstream: libmdbx **normalizes** the sync flags. Opening with
`SAFE_NOSYNC` reports `NOMETASYNC` as well, `UTTERLY_NOSYNC` reports both, and clearing the
stronger flag leaves the implied weaker one set. `mdbx_env_get_flags()` reports the environment's
actual state rather than the call that made it, so this shows through; it also ignores the
undocumented internal bit (`0x02000000`) libmdbx keeps in the same word.

Deferred to 0.2: `MDBX_opt_sync_bytes` / `MDBX_opt_sync_period`, the auto-sync thresholds that are
upstream's other companion to `SAFE_NOSYNC`. `mdbx_env_sync()` covers the manual case, and the
thresholds belong with the rest of the `mdbx_env_set_option()` surface.

---

