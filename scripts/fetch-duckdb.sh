#!/usr/bin/env bash
# Vendor the DuckDB C library (duckdb.h + libduckdb.so [+ libduckdb_static.a]) into vendor/.
# Override via env: DUCKDB_VERSION (default v1.3.2), DUCKDB_PLATFORM (linux-amd64, osx-universal, ...).
#
# NOTE: the prebuilt libduckdb_static.a is NOT self-contained (it leaves re2/fmt/mbedtls symbols
# undefined), so the default build links the complete libduckdb.so. A fully-static link needs a
# source build of DuckDB; see the README.
set -euo pipefail
VER="${DUCKDB_VERSION:-v1.3.2}"
PLAT="${DUCKDB_PLATFORM:-linux-amd64}"
DIR="$(cd "$(dirname "$0")/.." && pwd)/vendor"
mkdir -p "$DIR"
url="https://github.com/duckdb/duckdb/releases/download/${VER}/libduckdb-${PLAT}.zip"
echo "fetching $url"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/libduckdb.zip" "$url"
unzip -oq "$tmp/libduckdb.zip" -d "$tmp"
cp "$tmp/duckdb.h" "$DIR/"
[ -f "$tmp/libduckdb.so" ] && cp "$tmp/libduckdb.so" "$DIR/"
[ -f "$tmp/libduckdb_static.a" ] && cp "$tmp/libduckdb_static.a" "$DIR/"
echo "vendored DuckDB ${VER} (${PLAT}) into $DIR"
