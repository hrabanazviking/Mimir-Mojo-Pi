# Detect the effective virtual-address width at runtime instead of assuming 48 bits on aarch64

Fixes #82.

## Summary

`tcmalloc` hardcodes a 48-bit virtual address space on Linux/aarch64
(`kAddressBits = 48` in `tcmalloc/internal/config.h`). On kernels built
with a narrower user VA width — e.g. Raspberry Pi OS and Android GKI, which
ship `CONFIG_ARM64_VA_BITS=39` — every `mmap` hint
`SystemAllocator::RandomMmapHint()` generates (up to 2^47, with memory-tag
bits at bit 42) is rejected by the kernel. After 1000 retries
`MmapAligned()` returns null and the process aborts during allocator init:

```
FATAL ERROR: Out of memory. ... MmapAligned() failed: ... hint=0x2cdc00000000
```

This makes tcmalloc (and anything statically linking it, such as the Mojo
runtime) completely unusable on these kernels. There is no workaround short
of rebuilding the kernel.

This change makes tcmalloc detect the running kernel's VA width at runtime
and place its mmap hints and memory-tag bits accordingly, so a single
binary works on 39-bit, 42-bit, and 48-bit aarch64 kernels. On a 48-bit
kernel the behavior is bit-identical to before.

It also implements the advice the OOM error message itself gives: the
message suggests rebuilding "with `TCMALLOC_ADDRESS_BITS` defined", but no
such macro existed anywhere in the tree. It does now (aarch64/Linux).

## What changed

- **New `tcmalloc/internal/address_bits.{h,cc}`**: `EffectiveAddressBits()`
  probes the running kernel's user VA width by reading the most-significant
  set bit of the current stack pointer (the stack lives just below
  `TASK_SIZE`; this is the same probe ThreadSanitizer uses — no syscalls,
  no `/proc` parsing). The result is clamped to `[39, kAddressBits]` and
  cached; the width cannot change during a process's lifetime.
- **`tcmalloc/internal/memory_tag.h`**: `kTagShift`/`kTagMask` become the
  runtime functions `TagShift()`/`TagMask()` (39-bit kernel → shift 35;
  48-bit kernel → 42, exactly the old constant). Sanitizer builds are
  unaffected.
- **`tcmalloc/internal/system_allocator.h`**: `RandomMmapHint()` masks and
  tag placement use the runtime functions, so hints stay inside the
  effective address space. The TSan-only app-memory branch keeps
  compile-time tag placement (its hardcoded ranges already assume the full
  address space; sanitizer runs are test-only configurations).
- **`tcmalloc/tcmalloc.cc`**: the `kNormalMask`/`kColdMask`/bad-deallocation
  masks become `static const` (were `constexpr`) since tag placement is now
  runtime-detected. All uses are runtime comparisons; no constexpr context
  is affected.
- **`tcmalloc/internal/config.h`**: new `TCMALLOC_ADDRESS_BITS` build-time
  override (with `static_assert(<= 48)`); lowers the compile-time maximum
  and shrinks the page map for builders who want a fixed width.
- Test-only code (`huge_region_test`, `huge_page_aware_allocator_test`,
  the two fuzz targets, `mock_huge_page_static_forwarder.h`) updated to the
  new function names.
- `tcmalloc/internal/BUILD` gains the new `address_bits` sources.

## Test evidence

- `//tcmalloc/internal:config_test` and
  `//tcmalloc/internal:system_allocator_test`: **pass** on x86_64 Linux
  (48-bit kernel; patched lib reports bits=48/shift=42 — identical to
  pristine).
- A/B verification with a standalone (non-Bazel) build on both platforms:
  - **x86_64**: 200 allocations + 1 MiB-aligned reservation pass on the
    patched lib; pristine behaves identically — no regression. The test
    drives `TCMallocInternalMemalign`/`Free`, the same entry points the
    Mojo AsyncRT uses.
  - **Raspberry Pi 5, kernel 6.12.109+rpt-rpi-v8
    (`CONFIG_ARM64_VA_BITS=39`)**: the pristine library **aborts with the
    exact crash from #82**; the patched library reports
    `EffectiveAddressBits()=39`, `TagShift()=35`, and **all checks pass**.
