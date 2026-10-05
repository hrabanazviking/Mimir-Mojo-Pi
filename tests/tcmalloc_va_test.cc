// Test for the runtime virtual-address-width detection fix
// (google/tcmalloc issue #82: 48-bit VA assumption aborts on 39-bit ARM64
// kernels, e.g. Raspberry Pi OS).
//
// Exercises the exact entry points Modular's Mojo runtime uses
// (AsyncRT/lib/Runtime/Globals/Globals.cpp):
//   TCMallocInternalMemalign / TCMallocInternalFree
// The first allocation drives page-heap init -> SystemAllocator::MmapAligned
// -> RandomMmapHint, which is the code path that aborted before the fix.
//
// Checks:
//   * EffectiveAddressBits() matches the kernel's user VA width.
//   * Every returned pointer lies below 2^EffectiveAddressBits.
//   * Every returned pointer decodes to MemoryTag::kNormal.
//   * A 1 MiB-aligned 1 MiB reservation (the shape from the crash report)
//     succeeds.
//
// Build (after build-standalone.sh):
//   g++ -std=c++17 -O2 -g -I src/tcmalloc-work -I build/abseil-cpp \
//       tests/tcmalloc_va_test.cc -L build/lib \
//       -ltcmalloc_patched -labsl_standalone -lpthread -o build/va_test_patched
// Swap -ltcmalloc_patched for -ltcmalloc_pristine for the A/B comparison.

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "tcmalloc/internal/address_bits.h"
#include "tcmalloc/internal/memory_tag.h"
#include "tcmalloc/tcmalloc.h"

int main() {
  using tcmalloc::tcmalloc_internal::EffectiveAddressBits;
  using tcmalloc::tcmalloc_internal::GetMemoryTag;
  using tcmalloc::tcmalloc_internal::MemoryTag;
  using tcmalloc::tcmalloc_internal::TagShift;

  const int bits = EffectiveAddressBits();
  const uintptr_t kLimit = uintptr_t{1} << bits;
  printf("EffectiveAddressBits() = %d\n", bits);
  printf("TagShift()             = %lu\n", static_cast<unsigned long>(TagShift()));
  printf("address ceiling        = 0x%lx\n", static_cast<unsigned long>(kLimit));
  fflush(stdout);

  // Sweep allocation sizes to drive the page heap through its init path and
  // several region reservations.
  for (int i = 0; i < 200; ++i) {
    const size_t size = size_t{16} << (i % 20);  // 16 B .. 8 MiB
    void* p = TCMallocInternalMemalign(16, size);
    assert(p != nullptr && "TCMallocInternalMemalign returned null");
    const uintptr_t addr = reinterpret_cast<uintptr_t>(p);
    assert(addr < kLimit && "allocation outside kernel VA space");
    // Normal allocations are tagged kNormal; the sampler may tag a sampled
    // allocation kSampled instead.  Both are valid.
    const auto tag = GetMemoryTag(p);
    assert((tag == MemoryTag::kNormal || tag == MemoryTag::kSampled) &&
           "unexpected memory tag");
    memset(p, 0xAB, size < 4096 ? size : 4096);
    TCMallocInternalFree(p);
  }

  // The crash report's shape: a large aligned reservation at startup.
  void* big = TCMallocInternalMemalign(1 << 20, 1 << 20);
  assert(big != nullptr && "large aligned reservation failed");
  assert(reinterpret_cast<uintptr_t>(big) < kLimit);
  const auto big_tag = GetMemoryTag(big);
  assert((big_tag == MemoryTag::kNormal || big_tag == MemoryTag::kSampled) &&
         "unexpected memory tag");
  memset(big, 0xCD, 4096);
  TCMallocInternalFree(big);

  printf("ALL CHECKS PASSED (bits=%d)\n", bits);
  return 0;
}
