# Mimir-Mojo-Pi

> **Let's fix all the bugs so we can properly run Mojo on a Raspberry Pi.**

Mimir-Mojo-Pi is the engineering home for making [Modular's Mojo](https://github.com/modular/mojo)
run correctly on Raspberry Pi hardware. It collects root-cause analyses, minimal
upstream-quality patches, reproducible build scripts, and hardware test evidence —
starting with the bug that stops the `mojo` compiler driver from starting at all
on Pi OS.

The project's rule: **fix it in code, use the patched build ourselves, and offer
every fix upstream.** No kernel swaps, no `LD_PRELOAD` hacks, no workarounds that
only work on one machine.

---

## The problem

On a Raspberry Pi 5 running Raspberry Pi OS (Debian 12, `aarch64`), the `mojo`
binary aborts *immediately* — `mojo --version` never even prints:

```
$ mojo --version
Aborted
```

This happens despite gigabytes of free RAM. It is not an out-of-memory
condition. It is a **virtual address-space** failure inside the process's own
memory allocator, and it affects every 39-bit ARM64 Linux kernel — Raspberry Pi
OS, many Android kernels, and other distros that build `arm64` with
`CONFIG_ARM64_VA_BITS=39` instead of 48.

## Root cause

The failure chain, traced through Modular's public build definitions:

```
mojo  (compiler driver binary)
 └─ links //AsyncRT:RuntimeGlobals
     └─ statically links Google tcmalloc 2.15
         └─ tcmalloc's startup init assumes a 48-bit virtual address space
             └─ abort on the Pi's 39-bit kernel
```

In detail:

1. `Mojo/tools/mojo` (the driver) links `//AsyncRT:RuntimeGlobals`
   (`AsyncRT/BUILD.bazel`), which links
   `@tcmalloc//tcmalloc:tcmalloc_internal_methods_only_numa_aware` — Google's
   tcmalloc, statically linked into the binary.
2. `AsyncRT/lib/Runtime/Globals/Globals.cpp` uses tcmalloc's *internal* API
   (`TCMallocInternalMemalign` / `TCMallocInternalFree`) for NUMA-partitioned
   allocations. Note the driver itself uses **jemalloc** as its global malloc
   on Linux — tcmalloc is only a linked-in library. But its static
   initializers still run at startup, and they are what abort.
3. Inside tcmalloc, `tcmalloc/internal/config.h` hardcodes for
   `__aarch64__ && __linux__`:
   ```cpp
   inline constexpr int kAddressBits = 48;
   ```
4. `kAddressBits` feeds `SystemAllocator::RandomMmapHint()`
   (`tcmalloc/internal/system_allocator.h`), which builds `mmap` hints spanning
   up to 2⁴⁷ with memory-tag bits placed at bit 42
   (`kTagShift = min(kAddressBits - 4, 42)`, `tcmalloc/internal/memory_tag.h`).
5. On a 39-bit kernel every such hint lies outside the user address space, so
   `mmap(hint, MAP_FIXED_NOREPLACE)` fails ~1000 times, `MmapAligned()` returns
   null, and the allocator aborts during init. The process dies trying to
   *reserve* virtual address ranges that cannot exist — never touching real RAM.

A secondary bug: `MmapAligned()`'s failure message advises rebuilding "with
`TCMALLOC_ADDRESS_BITS` defined to your system's virtual address space size" —
but no such macro existed anywhere in the tree. The advice was impossible to
follow.

Because tcmalloc is **statically linked**, no environment variable,
`LD_PRELOAD`, or shared-library swap can work around this. The only real fixes
are rebuilding with corrected code — which is what this repo does.

## The fix

`patches/tcmalloc-39bit-va.patch` (see `PATCH.md` for the full write-up)
keeps `kAddressBits = 48` as the **compile-time maximum** — all data structures
(the page map, span bitfields, statistics arrays) stay sized for it, which is
provably safe on narrower kernels since those structures merely over-provision
slightly — and detects the **effective** width at runtime, clamping only the two
things that actually generate or interpret addresses:

- **New** `tcmalloc/internal/address_bits.{h,cc}`:
  `int EffectiveAddressBits()`. On Linux/aarch64 it reads the most significant
  set bit of the current stack pointer — the kernel maps the stack just below
  `TASK_SIZE`, so this reveals the kernel's user VA width. This is the same
  probe sanitizer runtimes use (e.g. TSan's VMA-size detection): no syscalls,
  no `/proc` parsing. The result is clamped to `[39, kAddressBits]` and cached.
  On a 48-bit kernel it returns 48 and every downstream computation is
  bit-identical to the pre-patch behavior. On other platforms it equals
  `kAddressBits` (no behavior change).
- `tcmalloc/internal/memory_tag.h`: `kTagShift`/`kTagMask` become
  `TagShift()`/`TagMask()` — the same formulas, evaluated against
  `EffectiveAddressBits()` (39-bit → shift 35, 48-bit → shift 42 as before).
- `tcmalloc/internal/system_allocator.h`: `RandomMmapHint()` masks hints to
  the effective width and places tags via the runtime functions.
- `tcmalloc/internal/config.h`: the previously-advertised
  `TCMALLOC_ADDRESS_BITS` macro now actually exists (aarch64 only) — defining
  it lowers the compile-time maximum, which also shrinks the page map. The
  failure message's advice is now real.

Design trade-offs, edge cases (47-bit Pi 5 configs, 52-bit kernels), and the
full test matrix are documented in [`PATCH.md`](PATCH.md).

## Repository layout

```
Mimir-Mojo-Pi/
├── README.md                        # this file
├── PATCH.md                         # full root-cause analysis and patch design
├── patches/
│   └── tcmalloc-39bit-va.patch      # the upstream-ready patch (diff -ruN)
├── build/
│   └── build-standalone.sh          # reproducible standalone build
│                                     # (abseil-cpp pinned to tcmalloc's MODULE.bazel)
└── tests/
    └── tcmalloc_va_test.cc          # drives TCMallocInternalMemalign/Free,
                                     # the exact entry points Mojo's runtime uses
```

## Status

| Item | State |
|---|---|
| Root cause identified and documented | ✅ Done |
| Patch written (`tcmalloc-39bit-va.patch`) | ✅ Done |
| x86_64 build + tests (48-bit kernel) | ✅ All checks passed — bit-identical behavior |
| Raspberry Pi 5 A/B test (39-bit kernel) | 🔄 In progress — pristine lib expected to abort (bug repro), patched lib expected to report 39-bit and pass |
| Upstream PR to google/tcmalloc (issue #82) | ⏳ After Pi verification + maintainer review |

## Building and testing

Prerequisites: a C++17 compiler, CMake or a plain `g++` invocation (see the
build script), and patience — tcmalloc plus abseil is a few hundred sources.

```bash
# Fetch the exact tcmalloc commit Modular's Bazel build pins, plus abseil
# at the version pinned in tcmalloc's MODULE.bazel, then build pristine
# and patched static libraries side by side:
bash build/build-standalone.sh

# Run the allocator test against the patched library:
g++ -std=c++17 tests/tcmalloc_va_test.cc -Lbuild/patched -ltcmalloc -labsl_... -o va_test
./va_test
```

On the Pi, the same script performs the A/B comparison: the pristine library
reproduces the abort, the patched library initializes cleanly.

## Upstream

This fix is intended for [google/tcmalloc](https://github.com/google/tcmalloc)
as a resolution of [issue #82](https://github.com/google/tcmalloc/issues/82)
(tcmalloc aborting on sub-48-bit ARM64 kernels). The patch targets the exact
commit Modular's build pins; before opening the PR it will be rebased onto
tcmalloc `master` and run against tcmalloc's own Bazel test suite
(`config_test`, `system_allocator_test`) on both 48-bit and 39-bit aarch64.

## Scope

This repo is about **Mojo on the Raspberry Pi, fixed properly**. The tcmalloc
allocator fix is the first entry because it is the critical path — nothing
Mojo-related runs on the Pi until the driver can start. Further Pi-specific
Mojo fixes (driver rebuilds, packaging, Pi-optimized build configs) will land
here as they are root-caused, always with the same discipline: minimal patch,
reproducible build, hardware test evidence, offered upstream.

Related work: [Project Aesir](https://github.com/hrabanazviking/RuneForgeAI-Project-Aesir)
(the bare-metal Mojo inference engine this unblocks) and the
[Hailo-10 open-stack roadmap](https://github.com/hrabanazviking/RuneForgeAI-Project-Aesir)
(independent host-stack work, tracked in the Aesir repo).

## License

Apache License 2.0 — see [LICENSE](LICENSE). This matches both upstreams the
work derives from (Google tcmalloc and Modular Mojo), keeping the contribution
path clean.
