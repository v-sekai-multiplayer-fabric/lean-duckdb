import LeanDuckDB

open DuckDB

/-- `duckdb-demo [path.parquet [column]]`.
With a path: prints row count and (optionally) a numeric column. With no args: a self-test that
round-trips a tiny table through Parquet entirely inside DuckDB. -/
def main (args : List String) : IO Unit := do
  match args with
  | path :: rest =>
    IO.println s!"{path}: {← rowCount path} rows"
    match rest with
    | col :: _ => IO.println s!"{col} = {(← columnFloat path col).toList}"
    | [] =>
      let t ← readParquet path
      IO.println s!"columns: {t.columns.toList}"
  | [] =>
    let tmp := "/tmp/lean_duckdb_selftest.parquet"
    let _ ← query s!"COPY (SELECT i, i*i AS sq FROM range(5) t(i)) TO '{tmp}' (FORMAT PARQUET)"
    let n ← rowCount tmp
    let sq ← columnFloat tmp "sq"
    IO.println s!"self-test: {n} rows, sq = {sq.toList}"
    if n == 5 && sq == #[0.0, 1.0, 4.0, 9.0, 16.0] then
      IO.println "OK"
    else
      throw <| IO.userError s!"self-test mismatch: n={n} sq={sq.toList}"
