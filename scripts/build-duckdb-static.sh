#!/usr/bin/env bash
# Build DuckDB from its C-amalgamation SOURCE into a self-contained, statically
# linkable archive — no prebuilt binaries are downloaded or linked — WITH the
# parquet and json extensions compiled in from the matching-version source tree.
#
# The release amalgamation (libduckdb-src.zip) ships the CORE engine only; the
# parquet/json extension implementations are NOT in it (they are gated behind
# DUCKDB_EXTENSION_{PARQUET,JSON}_LINKED, which #include headers absent from the
# zip). We therefore also fetch the full v<VER> source tree and compile:
#   * the amalgamation duckdb.cpp WITH -DDUCKDB_EXTENSION_{PARQUET,JSON}_LINKED=1
#     (so the static-extension load hooks are active), and
#   * extension/parquet/** + extension/json/** + their thirdparty (thrift, snappy,
#     lz4, brotli, parquet_types). yyjson and zstd are already compiled into the
#     amalgamation, so they are NOT rebuilt (that would duplicate symbols); the
#     extension objects resolve `duckdb_yyjson::*` / `duckdb_zstd::*` against it.
#
# The archive is ENCAPSULATED behind DuckDB's C API so it can be static-linked
# into a Lean 4 executable, whose toolchain otherwise fights us on two fronts:
#   1. C++ runtime ABI — Lean links its own libc++/libc++abi; DuckDB is built
#      with GNU libstdc++. The two share Itanium-ABI symbols (std::exception,
#      type_info, operator new, ...) and would collide. We whole-archive the
#      complete libstdc++ INTO one relocatable object and then LOCALIZE every
#      symbol except the `duckdb_*` C API, so DuckDB's C++ runtime is private
#      and invisible to Lean's linker.
#   2. glibc version — Lean bundles an older glibc than the host. A tiny compat
#      shim (native/duckdb_glibc_compat.c) supplies the few missing symbols
#      (__isoc23_*, pthread_cond_clockwait, __libc_single_threaded); it too is
#      localized into the object.
# DuckDB's C API never propagates C++ exceptions across the FFI boundary, so its
# embedded (localized) unwinder stays self-contained.
#
# Output: vendor/duckdb.h  +  vendor/libduckdb.a  (one encapsulated object)
# Override: DUCKDB_VERSION (default v1.3.2), CXX/CC, DUCKDB_OPT (default -O2).
set -euo pipefail
VER="${DUCKDB_VERSION:-v1.3.2}"
OPT="${DUCKDB_OPT:--O2}"
CXX="${CXX:-c++}"
CC="${CC:-cc}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/vendor"
BUILD="$DIR/amalgamation"
SRC="$BUILD/duckdb-src"          # full source tree (extensions + internal headers)
OBJ="$BUILD/obj"                 # per-TU extension/thirdparty objects
mkdir -p "$BUILD"

# Idempotent: the Lake target re-invokes this on every build; only do work once.
if [ -f "$DIR/libduckdb.a" ] && [ -f "$DIR/duckdb.h" ]; then
  echo "duckdb: encapsulated static archive already present ($DIR/libduckdb.a)"
  exit 0
fi

# 1a. amalgamation SOURCE (core engine, single TU) — not a prebuilt binary.
if [ ! -f "$BUILD/duckdb.cpp" ] || [ ! -f "$BUILD/duckdb.h" ]; then
  url="https://github.com/duckdb/duckdb/releases/download/${VER}/libduckdb-src.zip"
  echo "duckdb: fetching amalgamation SOURCE $url"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/src.zip" "$url"
  unzip -oq "$tmp/src.zip" -d "$BUILD"
fi

# 1b. full source TREE — for the parquet/json extension sources + internal
#     headers the amalgamation does not carry.
if [ ! -d "$SRC/extension/parquet" ]; then
  url="https://github.com/duckdb/duckdb/archive/refs/tags/${VER}.tar.gz"
  echo "duckdb: fetching full source tree SOURCE $url (for parquet/json extensions)"
  tmp2="$(mktemp -d)"; trap 'rm -rf "${tmp:-}" "$tmp2"' EXIT
  curl -fsSL -o "$tmp2/src.tar.gz" "$url"
  mkdir -p "$SRC"
  tar xzf "$tmp2/src.tar.gz" -C "$tmp2"
  # tarball extracts to duckdb-<ver-without-v>/
  inner="$(find "$tmp2" -maxdepth 1 -type d -name 'duckdb-*' | head -1)"
  cp -a "$inner"/. "$SRC"/
fi

# Include set matching DuckDB's own core+extension build. yyjson+zstd headers are
# needed for declarations even though their objects live in the amalgamation.
INCS="-I $SRC/src/include -I $SRC/third_party/fmt/include -I $SRC/third_party/re2 \
 -I $SRC/third_party/fsst -I $SRC/third_party/utf8proc/include -I $SRC/third_party/miniz \
 -I $SRC/third_party/hyperloglog -I $SRC/third_party/fastpforlib -I $SRC/third_party/skiplist \
 -I $SRC/third_party/tdigest -I $SRC/third_party/mbedtls/include -I $SRC/third_party/jaro_winkler \
 -I $SRC/third_party/concurrentqueue -I $SRC/third_party/fast_float -I $SRC/third_party/pcg \
 -I $SRC/third_party/yyjson/include -I $SRC/third_party/zstd/include \
 -I $SRC/extension/core_functions/include -I $SRC/extension/json/include \
 -I $SRC/extension/parquet/include -I $SRC/third_party/parquet -I $SRC/third_party/thrift \
 -I $SRC/third_party/snappy -I $SRC/third_party/lz4 -I $SRC/third_party/brotli/include"
# core_functions carries the standard aggregate/scalar library (sum, min, math,
# string, ...); json + parquet carry read_json_auto / read_parquet / COPY TO
# PARQUET. All three are gated OFF in the amalgamation by default.
DEFS="-DDUCKDB_EXTENSION_CORE_FUNCTIONS_LINKED=1 -DDUCKDB_EXTENSION_PARQUET_LINKED=1 -DDUCKDB_EXTENSION_JSON_LINKED=1"

# 2. compile the amalgamation (~22 MB single TU; several minutes) WITH the
#    extension load hooks active (so `read_json_auto`, COPY TO PARQUET, etc. are
#    routed to the statically linked extensions).
if [ ! -f "$BUILD/duckdb.o" ]; then
  echo "duckdb: compiling amalgamation duckdb.cpp -> duckdb.o ($OPT +extensions, several minutes)"
  "$CXX" -std=c++11 "$OPT" -fPIC -DNDEBUG -w $DEFS -I "$BUILD" $INCS \
    -c "$BUILD/duckdb.cpp" -o "$BUILD/duckdb.o"
fi

# 3. compile parquet + json extension sources and their thirdparty (thrift,
#    snappy, lz4, brotli, parquet_types). yyjson/zstd deliberately excluded.
if [ ! -f "$BUILD/ext.stamp" ]; then
  echo "duckdb: compiling core_functions + parquet + json extension sources"
  mkdir -p "$OBJ"
  mapfile -t EXT_SRCS < <(
    find "$SRC/extension/core_functions" -name '*.cpp'
    find "$SRC/extension/parquet" -name '*.cpp'
    find "$SRC/extension/json" -name '*.cpp'
    echo "$SRC/third_party/parquet/parquet_types.cpp"
    echo "$SRC/third_party/thrift/thrift/protocol/TProtocol.cpp"
    echo "$SRC/third_party/thrift/thrift/transport/TTransportException.cpp"
    echo "$SRC/third_party/thrift/thrift/transport/TBufferTransports.cpp"
    echo "$SRC/third_party/snappy/snappy.cc"
    echo "$SRC/third_party/snappy/snappy-sinksource.cc"
    echo "$SRC/third_party/lz4/lz4.cpp"
    find "$SRC/third_party/brotli" -name '*.cpp'
  )
  pids=(); fail=0
  for s in "${EXT_SRCS[@]}"; do
    o="$OBJ/$(printf '%s' "$s" | md5sum | cut -c1-12)_$(basename "$s").o"
    "$CXX" -std=c++11 "$OPT" -fPIC -DNDEBUG -w $DEFS $INCS -c "$s" -o "$o" &
    pids+=($!)
    if (( ${#pids[@]} >= $(nproc) )); then wait "${pids[0]}" || fail=1; pids=("${pids[@]:1}"); fi
  done
  for p in "${pids[@]}"; do wait "$p" || fail=1; done
  [ "$fail" -eq 0 ] || { echo "duckdb: extension compile failed"; exit 1; }
  touch "$BUILD/ext.stamp"
fi

# 4. glibc-compat shim for symbols Lean's bundled glibc lacks. MUST be -std=gnu11
#    without _GNU_SOURCE, else the host headers redirect strtol/sscanf/... to the
#    __isoc23_* symbols we define here (infinite self-recursion at runtime).
echo "duckdb: compiling glibc-compat shim (-std=gnu11)"
"$CC" -std=gnu11 -O2 -fPIC -c "$ROOT/native/duckdb_glibc_compat.c" -o "$BUILD/duckdb_glibc_compat.o"

# 5. resolve the GNU C++ runtime static via the compiler that built DuckDB.
#    NB: libgcc_eh is deliberately NOT embedded — its DWARF unwinder pulls a hard
#    dependency on glibc>=2.35 `_dl_find_object` and aborts when it is faked out.
#    DuckDB's `_Unwind_*` are left undefined and resolve to the LLVM libunwind
#    that Lean already links (same Itanium ABI; libstdc++ EH runs fine on it).
STDCXX_A="$("$CXX" -print-file-name=libstdc++.a)"
[ -f "$STDCXX_A" ] || { echo "duckdb: cannot find libstdc++.a ($STDCXX_A)"; exit 1; }

# 6. partial-link into ONE relocatable object: DuckDB core + extensions + shim,
#    with the complete libstdc++ whole-archived in (so no C++ std symbol is left
#    for Lean's linker).
echo "duckdb: partial-linking encapsulated object (duckdb + extensions + libstdc++ + shim)"
ld -r -o "$BUILD/duckdb_full.o" \
  "$BUILD/duckdb.o" "$OBJ"/*.o "$BUILD/duckdb_glibc_compat.o" \
  --whole-archive "$STDCXX_A" --no-whole-archive

# 7. localize every symbol except the DuckDB C API — hides the private C++ runtime
#    so it cannot collide with Lean's libc++abi.
echo "duckdb: localizing all symbols except the duckdb_* C API"
objcopy --wildcard --keep-global-symbol='duckdb_*' "$BUILD/duckdb_full.o" "$BUILD/duckdb_api.o"

# 8. archive + header.
ar rcs "$DIR/libduckdb.a" "$BUILD/duckdb_api.o"
cp "$BUILD/duckdb.h" "$DIR/duckdb.h"
# Drop large intermediates; keep the source + duckdb.o cache for fast rebuilds.
rm -f "$BUILD/duckdb_full.o" "$BUILD/duckdb_api.o" "$BUILD/duckdb_glibc_compat.o"

leaked=$(nm -g --defined-only "$DIR/libduckdb.a" 2>/dev/null | grep ' T ' | grep -vc ' duckdb_' || true)
echo "duckdb: built encapsulated $DIR/libduckdb.a ($(du -h "$DIR/libduckdb.a" | cut -f1)); non-duckdb_ globals leaked: ${leaked:-0}"
