# tcmalloc: runtime virtual-address-width detection for Linux/aarch64

Fixes https://github.com/google/tcmalloc/issues/82 —
"statically-linked tcmalloc assumes a 48-bit virtual address space and aborts
on ARM64 kernels built with a narrower user VA (e.g. Raspberry Pi OS,
`CONFIG_ARM64_VA_BITS=39`)".

## Root cause

`tcmalloc/internal/config.h` hardcodes, for `__aarch64__ && __linux__`:

```cpp
inline constexpr int kAddressBits = 48;
```

`kAddressBits` feeds two things that break at **runtime** on a sub-48-bit kernel:

1. `SystemAllocator::RandomMmapHint()` (`tcmalloc/internal/system_allocator.h`)
   builds mmap hints as
   ```cpp
   constexpr uintptr_t kAddrMask = (uintptr_t{1} << (kAddressBits - 1)) - 1;
   ...
   uintptr_t addr = rnd_ & kAddrMask & ~(alignment - 1) & ~kTagMask;
   addr |= static_cast<uintptr_t>(tag) << kTagShift;   // kTagShift = 42
   ```
   With `kAddressBits=48`, hints carry tag bits at bit 42 and span up to 2⁴⁷.
   On a 39-bit kernel every such hint is outside the user address space, so
   `mmap(hint, MAP_FIXED_NOREPLACE)` fails ~1000 times and `MmapAligned()`
   returns null; the caller then aborts (`TC_BUG`/OOM during init). This is
   the observed crash: `mojo --version` aborting on Raspberry Pi OS despite
   gigabytes of free RAM — it is a *virtual reservation* failure, not an
   out-of-memory.

2. The memory tag position, `kTagShift = min(kAddressBits - 4, 42)` /
   `kTagMask` (`tcmalloc/internal/memory_tag.h`), which must stay consistent
   with hint generation.

Everything else that uses `kAddressBits` at compile time — the page map
(`PageMap3<kAddressBits - kPageShift>`), span page-id bitfields, statistics
arrays, `CheckAddressBits` asserts — is safe with the value 48 on a narrower
kernel: those structures merely over-provision slightly and all runtime
addresses satisfy the (now vacuous) `< 2⁴⁸` checks.

A secondary bug: `MmapAligned()`'s failure message advises rebuilding "with
`TCMALLOC_ADDRESS_BITS` defined to your system's virtual address space
size", but no such macro existed anywhere in the tree — the advice was
impossible to follow.

## The fix

Keep `kAddressBits = 48` as the **compile-time maximum** (data structures
stay sized for it) and detect the **effective** width at runtime, clamping
only the two things that generate/interpret addresses:

* **New** `tcmalloc/internal/address_bits.h` / `address_bits.cc`:
  `int EffectiveAddressBits()`. On Linux/aarch64 it returns the 1-based
  position of the most significant set bit of the current stack pointer —
  the kernel maps the stack just below `TASK_SIZE`, so this reveals the
  kernel's user VA width. This is the same probe sanitizer runtimes use
  (e.g. TSan's VMA-size detection): no syscalls, no `/proc` parsing.
  The result is clamped to `[39, kAddressBits]` (aarch64 Linux guarantees at
  least 39 bits; the allocator can never exceed its compile-time maximum)
  and cached after the first call. On a 48-bit kernel it returns 48 and
  every downstream computation is bit-identical to before. On other
  platforms it equals `kAddressBits` (no behavior change).
* `tcmalloc/internal/memory_tag.h`: `kTagShift`/`kTagMask` become
  `TagShift()`/`TagMask()` — same formulas, evaluated against
  `EffectiveAddressBits()` instead of the compile-time constant
  (39-bit → shift 35, 48-bit → shift 42 as before). `GetMemoryTag()` and all
  users updated.
* `tcmalloc/internal/system_allocator.h`: `RandomMmapHint()` masks hints
  with `(1 << (EffectiveAddressBits() - 1)) - 1` and places tags via
  `TagShift()`/`TagMask()`; `AllocateFromRegion()`'s `kTagFree` limit and
  the `MmapAligned()` size/alignment asserts use `TagShift()`/`TagMask()`.
  The ThreadSanitizer-only branch keeps the previous compile-time placement
  (its hardcoded app-memory ranges already assume the full space; sanitizer
  runs are test-only configurations).
* `tcmalloc/internal/config.h`: the previously-advertised
  `TCMALLOC_ADDRESS_BITS` macro now exists — defining it (aarch64 only)
  lowers the compile-time maximum (which also shrinks the page map). This
  makes the `MmapAligned()` failure message's advice real.
* `tcmalloc/internal/BUILD`: new `address_bits` `cc_library`, wired into
  `memory_tag`'s deps.
* Tests updated: `config_test.cc` (aarch64) now asserts
  `EffectiveAddressBits()` equals the kernel's `CONFIG_ARM64_VA_BITS`
  (falling back to the page-table-level derivation), instead of asserting
  the compile-time constant equals it; `system_allocator_test.cc` and
  `mock_huge_page_static_forwarder.h` use the runtime tag functions.

## Design notes / trade-offs

* A fully dynamic `kAddressBits` (variable page-map sizing etc.) would be a
  far larger change; it is unnecessary, because a 48-bit-sized page map
  works fine on 39-bit kernels — only hint/tag generation needed to adapt.
* The stack-MSB probe assumes the stack lives near the top of the user
  address space, which is true for Linux's top-down stack placement
  (modulo ASLR *within* the top region — the MSB is unaffected).
* 47-bit kernels (some Pi 5 configurations, `TASK_SIZE = 2⁴⁷`) are handled:
  the probe returns 47, tags move to shift 43→capped at 42, hints stay
  below 2⁴⁷.
* 52-bit kernels: user addresses default to the 48-bit range without an
  explicit hint, so the probe (correctly) reports 48.

## Test evidence

Standalone (non-Bazel) build mirroring Modular's
`tcmalloc_internal_methods_only_numa_aware` target
(`-DTCMALLOC_INTERNAL_METHODS_ONLY -DTCMALLOC_INTERNAL_NUMA_AWARE`),
plus a test driving the exact entry points Mojo's runtime uses
(`TCMallocInternalMemalign`/`TCMallocInternalFree`):

* **x86_64 (48-bit kernel)**: `EffectiveAddressBits() = 48`,
  `TagShift() = 42` — bit-identical to pre-patch behavior; 200 allocations
  (16 B–8 MiB) plus a 1 MiB-aligned 1 MiB reservation all succeed, all
  pointers below 2⁴⁸ with valid tags. **ALL CHECKS PASSED.**
* **Raspberry Pi 5, Pi OS kernel 6.12.109+rpt-rpi-v8
  (`CONFIG_ARM64_VA_BITS=39`, verified from `/proc/config.gz`)**, native
  A/B build on the Pi itself:
  * Pristine (unpatched) library **aborts** during allocator init:
    `MmapAligned() failed ... (hint=0x2cdc00000000, size=1073741824,
    alignment=1073741824)` followed by `Note: the allocation may have
    failed because TCMalloc assumes a 48-bit virtual address space size`
    and `FATAL ERROR: Out of memory trying to allocate internal tcmalloc
    data` — the exact reported `mojo` crash, reproduced (note the 1 GiB
    reservation shape from the original report, and the hint far above
    2³⁹).
  * Patched library: `EffectiveAddressBits() = 39`, `TagShift() = 35`
    (was 42), address ceiling `0x8000000000`; 200 allocations
    (16 B–8 MiB) plus a 1 MiB-aligned 1 MiB reservation all succeed,
    all pointers below 2³⁹ with valid tags. **ALL CHECKS PASSED.**
* Probe logic verified standalone on the Pi before the full build:
  stack address `0x7fe385210c` → MSB = 39.

Build script: `build/build-standalone.sh`
(builds abseil-cpp 20250814.0 — the version pinned in tcmalloc's
`MODULE.bazel` — then the pristine and patched tcmalloc static libs).
Test: `tests/tcmalloc_va_test.cc`.

Note: the Pi test tree was assembled from the pristine commit plus the
functional changes (new files + the `memory_tag.h`/`system_allocator.h`
edits); Bazel-only changes (`BUILD`, `config.h` ifdef, test-file updates)
were not needed for the standalone A/B build and were verified locally.
The canonical upstream patch is `patches/tcmalloc-39bit-va.patch` generated as `diff -ruN` against upstream commit
`12f255231938d30493186b0a037feedd70f5a1c1` (the exact commit Modular's
Bazel build pins).

Standalone-build caveat (test harness only, not the patch): tcmalloc
relies on static-initialization order between `static_vars.cc`
(`Static::system_allocator_`) and `tcmalloc.cc` (`TCMallocGuard`). A naive
`ar` archive + `-l` link can order them wrong, producing a segfault in
`MmapRegionFactory::Create` during early init that looks like a patch bug
but is purely a link-order artifact (Bazel orders this correctly). The Pi
A/B results above were obtained by linking the object files directly with
`static_vars.o` before `tcmalloc.o`.

## Upstream readiness

Remaining before opening the PR against google/tcmalloc:
1. Rebase onto current `master` (the patch targets the Sep-2025 commit
   Modular pins; master has since simplified `kAddressBits` to an
   unconditional 48 — the patch applies with minor context adjustment,
   and the `TCMALLOC_ADDRESS_BITS` ifdef belongs around that line).
2. Run tcmalloc's own Bazel test suite (`config_test`, `system_allocator_test`)
   on both 48-bit and 39-bit aarch64.
3. Consider whether upstream prefers the probe in `address_bits.*` or folded
   into an existing internal header.
4. Write the PR description referencing issue #82.

No remotes were touched; no PR opened — awaiting Volmarr's review.
