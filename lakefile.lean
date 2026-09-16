import Lake
open Lake DSL

package Hashi where
  version := v!"0.1.0"

lean_lib Hashi

@[default_target]
lean_exe hashi where
  root := `Main

@[default_target]
lean_exe hashi_tests where
  root := `Tests

lean_exe hashi_bench where
  root := `Bench

target hashiGroupO pkg : System.FilePath := do
  let objectFile := pkg.buildDir / "c" / "hashi_group.o"
  let source ← inputTextFile (pkg.dir / "c" / "hashi_group.c")
  buildO objectFile source #["-I", (← getLeanIncludeDir).toString] #["-fPIC", "-O3"]

extern_lib hashi_group pkg := do
  let objectFile ← hashiGroupO.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "hashi_group") #[objectFile]
