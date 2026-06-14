import Lake
open Lake DSL System

package «lean_duckdb» where
  -- Executables/tests link the DuckDB static archive directly (true static linking, no runtime
  -- libduckdb.so). Downstream consumers add the same to their own `moreLinkArgs` (see README).
  -- Link the FFI shim against the vendored DuckDB. NOTE on "static": DuckDB's prebuilt
  -- `libduckdb_static.a` is NOT self-contained (it leaves re2/fmt/mbedtls symbols undefined), so a
  -- standalone fully-static link needs a *source* build of those. We therefore link the complete
  -- shared `libduckdb.so` (still a compile/link-time FFI binding, not a CLI subprocess). To go fully
  -- static, drop in a complete `libduckdb_static.a` and swap the two lines below for:
  --   "-Wl,--start-group", "vendor/libduckdb_static.a", "-Wl,--end-group", "-lstdc++", ...
  moreLinkArgs := #[
    "-Lvendor", "-lduckdb",
    "-Wl,-rpath,$ORIGIN", "-Wl,-rpath,$ORIGIN/../../../vendor"
  ]

-- Auto-vendor DuckDB on `lake update` so this works as a git dependency: a downstream `require
-- lean_duckdb from git` followed by `lake update` fetches the binary, no manual step. Re-fetch by
-- deleting vendor/libduckdb.so. Override version/platform with DUCKDB_VERSION / DUCKDB_PLATFORM.
post_update pkg do
  let soFile := pkg.dir / "vendor" / "libduckdb.so"
  unless (← soFile.pathExists) do
    logInfo "lean-duckdb: vendoring DuckDB via scripts/fetch-duckdb.sh"
    let fetchSh := (pkg.dir / "scripts" / "fetch-duckdb.sh").toString
    let out ← IO.Process.output { cmd := "bash", args := #[fetchSh] }
    if out.exitCode != 0 then
      logError s!"lean-duckdb: fetch-duckdb.sh failed (exit {out.exitCode}):\n{out.stdout}\n{out.stderr}"
    else
      logInfo out.stdout

@[default_target]
lean_lib «LeanDuckDB» where

-- Compile the C FFI shim against the vendored duckdb.h.
target duckdb_shim.o pkg : FilePath := do
  let oFile := pkg.buildDir / "native" / "duckdb_shim.o"
  let srcJob ← inputTextFile <| pkg.dir / "native" / "duckdb_shim.c"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString, "-I", (pkg.dir / "vendor").toString]
  buildO oFile srcJob weakArgs #["-fPIC"] "cc" getLeanTrace

-- Bundle the shim object into a static lib the Lean lib/exe link against.
extern_lib libduckdbshim pkg := do
  let name := nameToStaticLib "duckdbshim"
  let shim ← duckdb_shim.o.fetch
  buildStaticLib (pkg.staticLibDir / name) #[shim]

@[default_target]
lean_exe «duckdb-demo» where
  root := `Main
