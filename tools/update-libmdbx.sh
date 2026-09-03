#!/bin/sh
# Re-vendor libmdbx at a given release tag and re-apply the local patch series.
#
# Usage:  tools/update-libmdbx.sh [VERSION]      e.g.  tools/update-libmdbx.sh 0.14.3
#
# Since the end of 2025 libmdbx is distributed only in amalgamated form, so the
# repository tree at a release tag already is the amalgamation -- there is no
# separate archive to download, and `make dist` merely prints a notice.
#
# The vendored sources in src/vendor/libmdbx are stored PATCHED: patches are
# applied here, by the maintainer, not at build time. R packages cannot rely on
# patch(1) being present on a user's machine.
#
# After running this, update the pin and checksums in .agents/vendoring.md and
# the expected version in tests/testthat/test-version.R.

set -eu

VERSION="${1:-0.14.3}"
TAG="v${VERSION}"
UPSTREAM="https://github.com/erthink/libmdbx.git"

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
vendor="${root}/src/vendor/libmdbx"
patches="${root}/tools/patches"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

echo "==> cloning ${UPSTREAM} at ${TAG}"
git clone --quiet --depth 1 --branch "${TAG}" "${UPSTREAM}" "${work}/src"

echo "==> provenance"
printf '    tag object : %s\n' "$(git -C "${work}/src" rev-parse "${TAG}")"
printf '    commit     : %s\n' "$(git -C "${work}/src" rev-parse "${TAG}^{commit}")"
printf '    amalgamation: %s\n' \
  "$(sed -n '1s/.*(\(v[^)]*\) at.*/\1/p' "${work}/src/mdbx.c")"

echo "==> upstream checksums (record these in .agents/vendoring.md)"
( cd "${work}/src" && shasum -a 256 mdbx.c mdbx.h mdbx-internals.h LICENSE NOTICE COPYRIGHT ) \
  | sed 's/^/    /'

echo "==> vendoring into src/vendor/libmdbx"
mkdir -p "${vendor}"
for f in mdbx.c mdbx.h mdbx-internals.h LICENSE NOTICE COPYRIGHT; do
  cp "${work}/src/${f}" "${vendor}/${f}"
done

echo "==> applying patch series"
for p in "${patches}"/*.patch; do
  printf '    %s\n' "$(basename "${p}")"
  patch -p1 --no-backup-if-mismatch -d "${root}" < "${p}"
done

echo "==> post-patch checksums (record these in tools/patches/README.md)"
( cd "${vendor}" && shasum -a 256 mdbx.c mdbx-internals.h ) | sed 's/^/    /'

cat <<'EOF'

==> next steps
    1. .agents/vendoring.md  - update pin, upstream checksums, release notes review
    2. tools/patches/README.md - update post-patch checksums
    3. tests/testthat/test-version.R - update the expected version
    4. R CMD INSTALL --preclean .   - must build with no warnings
    5. nm -u src/vendor/libmdbx/mdbx.o | grep -E 'assert|stderr'  - must be empty
    6. R CMD check --as-cran        - must report no WARNINGs
EOF
