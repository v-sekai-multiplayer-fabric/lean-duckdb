# lean-duckdb

A small [Lean 4](https://leanprover.github.io/) integration with [DuckDB](https://duckdb.org/) for
loading **Parquet** (and CSV/JSON) files into Lean — built so the Lean+Plausible "sim-first"
workflow can read the datasets it generates.

It binds the DuckDB C API through a tiny FFI shim (`native/duckdb_shim.c`) that runs a SQL statement
against a fresh in-memory database and returns the result as TSV, which Lean parses. The binding is
**compile/link-time** (not a CLI subprocess).

## Quick start

```bash
./scripts/fetch-duckdb.sh        # vendor duckdb.h + libduckdb.so into vendor/ (v1.3.2 by default)
lake build                       # build the lib + the `duckdb-demo` exe
LD_LIBRARY_PATH=vendor ./.lake/build/bin/duckdb-demo            # self-test (round-trips a Parquet table)
LD_LIBRARY_PATH=vendor ./.lake/build/bin/duckdb-demo data.parquet dy   # rows + the `dy` column
```

## Library API

```lean
import LeanDuckDB
open DuckDB

let n     ← rowCount "data.parquet"                 -- Nat
let ys    ← columnFloat "data.parquet" "dy"         -- Array Float
let names ← columnStr "data.parquet" "interp"       -- Array String
let t     ← readParquet "data.parquet"              -- DuckDB.Table (columns + string rows)
let some i := t.colIndex "frame" | pure ()
let xs    := t.columnFloat "tx"                      -- Array Float
let raw   ← query "SELECT avg(min_cone_deg) AS m FROM read_parquet('data.parquet') WHERE in_region"
```

`query`/`readParquet`/`readCsv` return a `DuckDB.Table` (`columns : Array String`,
`rows : Array (Array String)`); `Table.column`, `Table.columnFloat`, `Table.colIndex` pull fields.
Arbitrary SQL (joins, aggregates, `read_parquet`/`read_csv_auto`/globs) works through `query`.

## Linking & the "static" caveat

Add this to **your** package's `moreLinkArgs` (consumers link DuckDB too):

```lean
moreLinkArgs := #["-Lvendor", "-lduckdb", "-Wl,-rpath,$ORIGIN", "-Wl,-rpath,$ORIGIN/../../../vendor"]
```

The default links the complete **`libduckdb.so`**. DuckDB's *prebuilt* `libduckdb_static.a` is **not
self-contained** — it leaves `re2`/`fmt`/`mbedtls` symbols undefined — so a standalone *fully static*
link requires building DuckDB (and those bundled deps) from source. With such a complete archive,
swap the link args for:

```lean
"-Wl,--start-group", "vendor/libduckdb_static.a", "-Wl,--end-group", "-lstdc++", "-lpthread", "-ldl", "-lm"
```

## Notes
- TSV transport: cells are tab-separated; values containing tabs/newlines are not escaped. Fine for
  numeric/identifier datasets (the intended use); for arbitrary text use `query` with explicit casts.
- Each `query` opens a fresh in-memory DB. Persisting state across calls is a future addition
  (the C API supports it; the shim keeps no global handle by design).
