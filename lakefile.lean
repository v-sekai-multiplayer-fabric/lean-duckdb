import Lake
open Lake DSL System

package «lean_duckdb» where
  -- TRUE static linking against a self-contained archive built from the DuckDB
  -- C-amalgamation SOURCE (scripts/build-duckdb-static.sh) — no prebuilt binary,
  -- no runtime libduckdb.so. The prebuilt `libduckdb_static.a` is NOT
  -- self-contained (undefined re2/fmt/mbedtls symbols); compiling the
  -- amalgamation bundles those, so `vendor/libduckdb.a` links standalone with
  -- just the C++ runtime + system libs. Downstream consumers add the same
  -- `--start-group vendor/libduckdb.a --end-group -lstdc++ ...` (see README).
  -- The encapsulated archive carries DuckDB's GNU C++ runtime internally (all
  -- non-`duckdb_*` symbols localized), so no libstdc++/libc++ flags are needed.
  moreLinkArgs := #[
    "-Wl,--start-group", "vendor/libduckdb.a", "-Wl,--end-group",
    "-lm", "-ldl", "-lpthread"
  ]

-- Auto-build DuckDB on `lake update` too, so a downstream `require lean_duckdb
-- from git` + `lake update` provisions the static archive with no manual step.
-- (The build target below also does this on a plain `lake build` — see
-- duckdb_shim.o.) Re-build by deleting vendor/libduckdb.a. Override version with
-- DUCKDB_VERSION.
post_update pkg do
  let aFile := pkg.dir / "vendor" / "libduckdb.a"
  unless (← aFile.pathExists) do
    logInfo "lean-duckdb: building DuckDB static archive via scripts/build-duckdb-static.sh"
    let buildSh := (pkg.dir / "scripts" / "build-duckdb-static.sh").toString
    let out ← IO.Process.output { cmd := "bash", args := #[buildSh] }
    if out.exitCode != 0 then
      logError s!"lean-duckdb: build-duckdb-static.sh failed (exit {out.exitCode}):\n{out.stdout}\n{out.stderr}"
    else
      logInfo out.stdout

@[default_target]
lean_lib «LeanDuckDB» where

-- Compile the C FFI shim against the amalgamation-built duckdb.h. One-stop:
-- a plain `lake build` first builds DuckDB from the C amalgamation source into a
-- self-contained static archive (vendor/libduckdb.a + vendor/duckdb.h) if it is
-- not already present — no manual vendoring, no prebuilt binary.
target duckdb_shim.o pkg : FilePath := do
  let vendorH := pkg.dir / "vendor" / "duckdb.h"
  let vendorA := pkg.dir / "vendor" / "libduckdb.a"
  unless (← vendorH.pathExists) && (← vendorA.pathExists) do
    logInfo "lean-duckdb: building DuckDB static archive from the C amalgamation (scripts/build-duckdb-static.sh)"
    let buildSh := (pkg.dir / "scripts" / "build-duckdb-static.sh").toString
    let out ← IO.Process.output { cmd := "bash", args := #[buildSh] }
    unless out.exitCode == 0 do
      error s!"lean-duckdb: build-duckdb-static.sh failed (exit {out.exitCode}):\n{out.stdout}\n{out.stderr}"
    logInfo out.stdout
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
