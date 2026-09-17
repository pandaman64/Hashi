import Lake
open Lake DSL

/-
An isolated release build with gprof instrumentation. Keeping a separate build
directory prevents `-pg` objects from contaminating normal benchmark results.
-/
package Hashi where
  version := v!"0.1.0"
  buildDir := ".lake/build-profile"
  moreLeancArgs := #["-pg"]
  moreLinkArgs := #["-pg"]

lean_lib Hashi

lean_exe hashi_profile where
  root := `Profile

target hashiGroupO pkg : System.FilePath := do
  let objectFile := pkg.buildDir / "c" / "hashi_group.o"
  let source ← inputTextFile (pkg.dir / "c" / "hashi_group.c")
  buildO objectFile source #["-I", (← getLeanIncludeDir).toString]
    #["-fPIC", "-O3", "-pg", "-DHASHI_GPROF"]

extern_lib hashi_group pkg := do
  let objectFile ← hashiGroupO.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "hashi_group") #[objectFile]
