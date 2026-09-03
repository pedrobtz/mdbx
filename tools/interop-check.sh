#!/usr/bin/env bash
# Interoperability spot-check: prove a database this package writes is readable
# by an independently built libmdbx, and the reverse.
#
# Everything else in the test suite verifies mdbx-in-R against itself, which
# cannot catch a difference in how bytes reach the file. The independent side is
# `clibmdbx`, the Python binding this package's design follows: its own vendored
# copy of libmdbx, built by a different compiler with different flags.
#
# Maintainer script, not part of R CMD check -- run it when bumping the vendored
# libmdbx, alongside tools/update-libmdbx.sh. Needs python3 and network access.
#
# Usage: tools/interop-check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== setting up the independent implementation =="
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --upgrade pip
"$work/venv/bin/pip" install --quiet clibmdbx
py="$work/venv/bin/python"

"$py" - <<'EOF'
import clibmdbx
print("clibmdbx %s, libmdbx %s" % (clibmdbx.__version__, clibmdbx.LIBMDBX_VERSION))
EOF
Rscript -e 'cat(sprintf("mdbx (R)  %s, libmdbx %s\n", as.character(packageVersion("mdbx")), mdbx::mdbx_version()$describe))'

# The corpus is deliberately awkward: multibyte UTF-8, an embedded NUL, an empty
# value, one large value, and keys inserted in the reverse of their sort order.
cat > "$work/write.R" <<'EOF'
library(mdbx)
path <- commandArgs(trailingOnly = TRUE)[[1]]
env <- mdbx_env_open(path, map_size = 64 * 1024^2)
mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "ascii", "plain value")
  mdbx_put(txn, "u8-ключ", "значение")
  mdbx_put(txn, as.raw(c(0x62, 0x69, 0x6e, 0x00, 0x6b)), as.raw(c(0x00, 0xff, 0x7f, 0x80)))
  mdbx_put(txn, "empty", raw(0))
  mdbx_put(txn, "large", paste(rep("x", 100000), collapse = ""))
  for (i in 10:1) mdbx_put(txn, sprintf("ord-%03d", i), as.character(i))
})
cat("  wrote", mdbx_env_stat(env)$entries, "records\n")
mdbx_env_close(env)
EOF

cat > "$work/read.py" <<'EOF'
import sys, clibmdbx
path, filler = sys.argv[1], sys.argv[2].encode()
expected = {
    b"ascii": b"plain value",
    "u8-ключ".encode(): "значение".encode(),
    b"bin\x00k": bytes([0x00, 0xFF, 0x7F, 0x80]),
    b"empty": b"",
    b"large": filler * 100000,
}
for i in range(1, 11):
    expected[("ord-%03d" % i).encode()] = str(i).encode()

env = clibmdbx.Environment(path, readonly=True, subdir=False)
with env.begin() as txn:
    with txn.cursor() as cur:
        got = dict(cur)
env.close()

bad = ["missing %r" % k for k in expected if k not in got]
bad += ["differs %r" % k for k, v in expected.items() if k in got and got[k] != v]
bad += ["unexpected %r" % k for k in got if k not in expected]
if list(got) != sorted(got):
    bad.append("key order is not byte order")
print("  read %d records; %s" % (len(got), "OK" if not bad else "FAIL: " + "; ".join(bad)))
sys.exit(1 if bad else 0)
EOF

cat > "$work/write.py" <<'EOF'
import sys, clibmdbx
path = sys.argv[1]
env = clibmdbx.Environment(path, subdir=False, geometry=(-1, -1, 64 << 20, -1, -1, -1))
with env.begin(write=True) as txn:
    txn.put(b"ascii", b"plain value")
    txn.put("u8-ключ".encode(), "значение".encode())
    txn.put(b"bin\x00k", bytes([0x00, 0xFF, 0x7F, 0x80]))
    txn.put(b"empty", b"")
    txn.put(b"large", b"y" * 100000)
    for i in range(10, 0, -1):
        txn.put(("ord-%03d" % i).encode(), str(i).encode())
    txn.commit()
with env.begin() as t:
    print("  wrote %d records" % t.stat()["entries"])
env.close()
EOF

cat > "$work/read.R" <<'EOF'
library(mdbx)
path <- commandArgs(trailingOnly = TRUE)[[1]]

expected <- list(
  ascii = charToRaw("plain value"),
  "u8-ключ" = charToRaw("значение"),
  empty = raw(0),
  large = charToRaw(paste(rep("y", 100000), collapse = ""))
)
for (i in 1:10) expected[[sprintf("ord-%03d", i)]] <- charToRaw(as.character(i))

env <- mdbx_env_open(path, readonly = TRUE)
items <- mdbx_with_read(env, function(txn) mdbx_items(txn, as = "raw"))
bad <- character(0)

find <- function(key) which(vapply(items$keys, identical, logical(1), key))

# The NUL-containing key is reachable only as raw, which is the point of it.
at <- find(as.raw(c(0x62, 0x69, 0x6e, 0x00, 0x6b)))
if (length(at) != 1L || !identical(items$values[[at]], as.raw(c(0x00, 0xff, 0x7f, 0x80)))) {
  bad <- c(bad, "NUL-containing key")
}

for (name in names(expected)) {
  at <- find(charToRaw(name))
  if (length(at) != 1L) {
    bad <- c(bad, sprintf("missing %s", name))
  } else if (!identical(items$values[[at]], expected[[name]])) {
    bad <- c(bad, sprintf("differs %s", name))
  }
}

# Text written by the other implementation must decode, not just round-trip.
if (!identical(mdbx_with_read(env, function(txn) mdbx_get(txn, "u8-ключ")),
               "значение")) {
  bad <- c(bad, "UTF-8 decode")
}
if (length(items$keys) != 15L) bad <- c(bad, "record count")

cat(sprintf("  read %d records; %s\n", length(items$keys),
            if (length(bad) == 0) "OK" else paste("FAIL:", paste(bad, collapse = "; "))))
mdbx_env_close(env)
if (length(bad) > 0) quit(status = 1)
EOF

echo
echo "== R writes, libmdbx reads =="
Rscript "$work/write.R" "$work/a.mdbx"
"$py" "$work/read.py" "$work/a.mdbx" x

echo
echo "== libmdbx writes, R reads =="
"$py" "$work/write.py" "$work/b.mdbx"
Rscript "$work/read.R" "$work/b.mdbx"

echo
echo "interop OK in both directions"
