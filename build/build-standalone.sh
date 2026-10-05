#!/bin/bash
# Standalone (non-Bazel) build of the patched tcmalloc, mirroring Modular's
# Bazel target `tcmalloc_internal_methods_only_numa_aware`:
#   copts = -DTCMALLOC_INTERNAL_METHODS_ONLY -DTCMALLOC_INTERNAL_NUMA_AWARE
# (no -DTCMALLOC_INTERNAL_8K_PAGES; that is only on the default target).
#
# Produces:
#   build/lib/libabsl_standalone.a
#   build/lib/libtcmalloc_patched.a   (from src/tcmalloc-work)
#   build/lib/libtcmalloc_pristine.a  (from src/google-tcmalloc, for A/B tests)
set -euo pipefail

ROOT="${TCMALLOC_FARM_ROOT:-$HOME/workspace/mojo-tcmalloc-fix}"
SRC_WORK="$ROOT/src/tcmalloc-work"
SRC_PRISTINE="$ROOT/src/google-tcmalloc"
ABSL="$ROOT/build/abseil-cpp"
OBJ="$ROOT/build/obj"
LIB="$ROOT/build/lib"
mkdir -p "$OBJ" "$LIB"

CXX="${CXX:-g++}"
JOBS="${JOBS:-$(nproc)}"
TCMALLOC_DEFINES="-DTCMALLOC_INTERNAL_METHODS_ONLY -DTCMALLOC_INTERNAL_NUMA_AWARE"
CXXFLAGS="-std=c++17 -O2 -g -fPIC $TCMALLOC_DEFINES -Wno-unused-parameter -Wno-sign-compare"

compile_set() {
  # $1 = label, $2 = include dirs, $3 = file with source list, $4 = output .a
  local label="$1" includes="$2" list="$3" out="$4"
  local objdir="$OBJ/$label"
  mkdir -p "$objdir"
  echo "[$label] compiling $(wc -l < "$list") sources with $JOBS jobs..."
  # shellcheck disable=SC2086
  xargs -a "$list" -P "$JOBS" -I{} sh -c '
    src="$1"; obj="$2/$(echo "$src" | tr "/" "_" | sed -e "s/\.cc$/.o/" -e "s/\.S$/.o/")"
    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
      '"$CXX"' '"$CXXFLAGS"' '"$includes"' -c "$src" -o "$obj" || echo "FAILED: $src" >&2
    fi
  ' _ {} "$objdir"
  # fail if any object is missing
  local expected actual
  expected=$(wc -l < "$list"); actual=$(ls "$objdir"/*.o 2>/dev/null | wc -l)
  if [ "$actual" -ne "$expected" ]; then
    echo "[$label] ERROR: $actual/$expected objects built" >&2
    exit 1
  fi
  ar rcs "$out" "$objdir"/*.o
  echo "[$label] -> $out"
}

if [ ! -f "$LIB/libabsl_standalone.a" ]; then
  find "$ABSL/absl" -name "*.cc" \
    | grep -v -e "_test\.cc" -e "_benchmark\.cc" -e "/testdata/" \
    -e "test_matchers\.cc" -e "scoped_mock_log\.cc" -e "status_matchers\.cc" \
    -e "/benchmarks\.cc" -e "exception_safety_testing\.cc" \
    -e "spinlock_test_common\.cc" -e "/test_helpers\.cc" \
    | sort > "$OBJ/absl-sources.txt"
  compile_set "absl" "-I$ABSL" "$OBJ/absl-sources.txt" "$LIB/libabsl_standalone.a"
else
  echo "[absl] cached $LIB/libabsl_standalone.a"
fi

build_tcmalloc() {
  # $1 = label, $2 = source root
  local label="$1" src="$2"
  { find "$src/tcmalloc" -name "*.cc" \
    | grep -v -e "_test\.cc" -e "_benchmark\.cc" -e "_fuzz\.cc" -e "_fuzzer\.cc" \
    -e "/testing/" -e "mock_transfer_cache\.cc" -e "profile_marshaler\.cc" \
    -e "mock_central_freelist\.cc" -e "profile_builder\.cc";
    find "$src/tcmalloc" -name "*.S" -name "percpu_rseq_asm.S"; } \
    | sort > "$OBJ/$label-sources.txt"
  # .S files are preprocessed assembly: compile with the C driver.
  local saved_cxx="$CXX"
  compile_set "$label" "-I$src -I$ABSL" "$OBJ/$label-sources.txt" "$LIB/lib$label.a"
}

if [ ! -f "$LIB/libtcmalloc_patched.a" ] || [ "${1:-}" = "tcmalloc" ]; then
  build_tcmalloc "tcmalloc_patched" "$SRC_WORK"
fi
if [ ! -f "$LIB/libtcmalloc_pristine.a" ] || [ "${1:-}" = "tcmalloc" ]; then
  build_tcmalloc "tcmalloc_pristine" "$SRC_PRISTINE"
fi

echo "BUILD DONE"
