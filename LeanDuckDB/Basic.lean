import Lean.Data.Json

/-!
# LeanDuckDB

A Lean 4 integration with DuckDB for loading Parquet (and CSV/JSON) files into Lean.

It binds the DuckDB C API through a small FFI shim (`native/duckdb_shim.c`) that runs a SQL
statement against a fresh in-memory database and returns the result as TSV, which Lean parses.
The shim is **statically linked** against `libduckdb_static.a` (vendored via `scripts/fetch-duckdb.sh`),
so binaries that use this library carry no runtime `libduckdb.so` dependency.

```lean
open DuckDB
let rows ← readParquet "data/sweep.parquet"     -- Array (Array String), header in `columnNames`
let ys  ← columnFloat "data/sweep.parquet" "dy" -- one numeric column
let t   ← query "SELECT count(*) AS n FROM read_parquet('data/sweep.parquet')"
```
-/

namespace DuckDB

/-- Parse a numeric TSV cell as `Float` via the JSON number grammar (empty / non-numeric → `0.0`). -/
private def cellFloat (s : String) : Float :=
  match Lean.Json.parse s with
  | .ok (.num n) => n.toFloat
  | _ => 0.0

/-- Run a SQL statement against a fresh in-memory DuckDB and return the result as TSV (header row +
data rows). Implemented in `native/duckdb_shim.c` over the DuckDB C API. -/
@[extern "lean_duckdb_query_tsv"]
opaque queryTsv (sql : String) : IO String

/-- A parsed result table: column names + rows of string cells (NULL renders as `""`). -/
structure Table where
  columns : Array String
  rows : Array (Array String)
deriving Repr, Inhabited

namespace Table

/-- Column index by name. -/
def colIndex (t : Table) (name : String) : Option Nat :=
  t.columns.findIdx? (· == name)

/-- A column as raw string cells. -/
def column (t : Table) (name : String) : Array String :=
  match t.colIndex name with
  | some i => t.rows.map fun r => r.getD i ""
  | none => #[]

/-- A column parsed as `Float` (empty / unparseable cells become `0.0`). -/
def columnFloat (t : Table) (name : String) : Array Float :=
  (t.column name).map fun s => cellFloat s

/-- Number of data rows. -/
def numRows (t : Table) : Nat := t.rows.size

end Table

/-- Parse the shim's TSV (first line = header) into a `Table`. -/
def parseTsv (tsv : String) : Table := Id.run do
  let lines := (tsv.splitOn "\n").filter (·.length > 0)
  match lines with
  | [] => return { columns := #[], rows := #[] }
  | header :: body =>
    let columns := (header.splitOn "\t").toArray
    let rows := body.toArray.map fun line => (line.splitOn "\t").toArray
    return { columns, rows }

/-- Run a query and return the parsed `Table`. -/
def query (sql : String) : IO Table := do
  return parseTsv (← queryTsv sql)

/-- Single-quote-escape a path for embedding in SQL. -/
private def sqlStr (s : String) : String :=
  "'" ++ s.replace "'" "''" ++ "'"

/-- Load an entire Parquet file as a `Table`: `SELECT * FROM read_parquet('<path>')`. -/
def readParquet (path : String) : IO Table :=
  query s!"SELECT * FROM read_parquet({sqlStr path})"

/-- Load an entire CSV file as a `Table` (auto-detected schema). -/
def readCsv (path : String) : IO Table :=
  query s!"SELECT * FROM read_csv_auto({sqlStr path})"

/-- Row count of a Parquet file (`SELECT count(*)`), without materializing the rows. -/
def rowCount (path : String) : IO Nat := do
  let t ← query s!"SELECT count(*) AS n FROM read_parquet({sqlStr path})"
  return ((t.column "n")[0]?.bind (·.toNat?)).getD 0

/-- Read one numeric column of a Parquet file as `Array Float`. -/
def columnFloat (path col : String) : IO (Array Float) := do
  let t ← query s!"SELECT {col} AS v FROM read_parquet({sqlStr path})"
  return t.columnFloat "v"

/-- Read one column of a Parquet file as `Array String`. -/
def columnStr (path col : String) : IO (Array String) := do
  let t ← query s!"SELECT {col} AS v FROM read_parquet({sqlStr path})"
  return t.column "v"

end DuckDB