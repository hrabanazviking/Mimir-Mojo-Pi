# Test log — tcmalloc 39-bit VA fix, rebased onto google/tcmalloc master

Date: 2026-10-05. Master commit: `8f894ec4` ("Remove dead TCMALLOC_INTERNAL_WITH_ASSERTIONS...").
Rebased patch: `patches/tcmalloc-39bit-va-master.patch` (13 files, applies cleanly to pristine master — verified with `patch -p1 --dry-run`).

## 1. Rebase verification

The original patch targeted upstream commit `12f25523`. Rebased onto current master:
- `config.h`: master had simplified `kAddressBits` to an unconditional `48`; the new `TCMALLOC_ADDRESS_BITS` ifdef was hand-applied around that line.
- `memory_tag.h`, `system_allocator.h`, `mock_huge_page_static_forwarder.h`: rejected hunks hand-applied.
- Master added NEW users of the old `kTagShift`/`kTagMask` constexprs after `12f25523` (not covered by the original patch): `tcmalloc/tcmalloc.cc` (`kNormalMask`, `kColdMask`, bad-deallocation masks — converted `constexpr` → `const` since tag placement is now runtime-detected; all uses are runtime comparisons) and four test/fuzz files (`huge_region_test.cc`, `huge_region_fuzz.cc`, `huge_page_aware_allocator_test.cc`, `huge_page_aware_allocator_fuzz.cc` — mechanical `kTagShift` → `TagShift()`, `kTagMask` → `TagMask()`).
- Result: zero remaining references to the old constexprs (excluding the unrelated `selsan/` namespaced copies and the intentional `kTagShiftC`/`kTagMaskC` in the TSan-only branch).

## 2. Compilation (master + patch, x86_64)

Full non-test tcmalloc tree compiled with g++ (`-std=c++17 -O2`): **74/74 objects, 0 errors** (against abseil-cpp 20260526.0, the exact version master's MODULE.bazel pins).
The two test sources (`tcmalloc/internal/config_test.cc`, `tcmalloc/internal/system_allocator_test.cc`) compile cleanly; both test binaries link.

## 3. Runtime probe (x86_64, 48-bit kernel)

```
EffectiveAddressBits=48  TagShift=42  TagMask=0x1c0000000000  kAddressBits=48
```

Bit-identical to the old compile-time constants — no behavior change on 48-bit kernels, as designed.

## 4. Upstream test binaries — sandbox limitation (not a patch failure)

`config_test` and `system_allocator_test` were built from the exact upstream test sources and run on x86_64. Both abort at startup in `Arena::AllocSlow`: tcmalloc's first page-heap reservation — a `mmap(hint, size, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE)` with a well-formed hint — returns `ENOMEM` from the kernel.

**This is environmental, not caused by the patch:**
- A pristine (unpatched) master tree, built and run identically, **fails in exactly the same way** (same call site, same `ENOMEM`).
- The identical syscall (same address, size, flags) **succeeds in fresh processes**, including processes with tcmalloc linked as the global allocator, and even from pre-`main` constructors.
- Address-space inspection at the failure moment shows a normal layout (45 VMAs, hint region fully free); `RLIMIT_AS` is unlimited.
- Suspected cause: an interaction between this sandboxed VM (seccomp-filtered, hypervisor-ballooned memory) and large `MAP_FIXED_NOREPLACE` reservations in the test process. The mechanism was not fully identified.
- Bazel itself could not be used here either: its module downloads crash in the sandbox's egress-proxy tunneling (`NoSuchElementException` in `HttpURLConnection.doTunneling`), so the tests were built with g++ directly from the same sources Bazel would compile.

**Primary test evidence therefore remains the standalone A/B verification** (done 2026-10-05, see PATCH.md):
- x86_64: patched lib — 200 allocations + 1 MiB-aligned reservation pass; pristine behaves identically (no regression).
- Raspberry Pi 5 (`CONFIG_ARM64_VA_BITS=39`): pristine lib aborts with the exact crash from google/tcmalloc#82; patched lib reports `EffectiveAddressBits()=39`, `TagShift()=35`, all checks pass.

## 5. Pi-side Bazel tests

Not run: the Pi is currently at load ~7.4 running the parallel Mojo driver Bazel build. Per the standing rule to keep Pi work light and not contend with that build, the already-completed Pi A/B verification stands as the Pi-side evidence.
