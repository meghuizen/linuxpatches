# lockref: adjust the count with a single addition (v2, standalone)

One patch, sent on its own; it does not depend on the vfs series and the
vfs series does not depend on it. Base: v7.3-rc3 (518e5b794c06); the
file has not changed upstream since (last commit to lib/lockref.c:
2026-07-24). Branch `sub-lockref-v2` in `/usr/src/linux-pt-lockref`,
tip 30ea4a728531.

Changes from the first version (which was in `../removed/`):

- 32-bit targets keep `new.count++`/`--`: the word add regressed i386
  (lockref_get 42 -> 51 instructions). Now the i386 object is identical
  to the unpatched one; the 64-bit objects are identical to v1.
- The comment no longer claims the lock half is zero when the update is
  made (false on ticket-spinlock arches, and not needed): the argument
  is that the add cannot reach the lock half on little-endian at all,
  and on big-endian only from counts the fast paths never store from.
- Changelog carries kernel-object instruction counts for x86-64, i386,
  arm64 and riscv64, the big-endian equivalence check, and the honest
  in-kernel result (not measurable at syscall level).

Evidence: `../tests/lockref-isa/RESULTS.md`.

Recipients (`get_maintainer.pl -f lib/lockref.c` gives only Andrew
Morton and lkml; the rest are the file's author and recent contributors):

    To: Andrew Morton <akpm@linux-foundation.org>
    Cc: Linus Torvalds <torvalds@linux-foundation.org>
    Cc: Mateusz Guzik (lockref changes 2023, 2026; address from lore)
    Cc: Christoph Hellwig <hch@lst.de>
    Cc: Uros Bizjak (try_cmpxchg64 in CMPXCHG_LOOP, 3378323bbb9e; address from that commit)
    Cc: linux-fsdevel@vger.kernel.org
    Cc: linux-kernel@vger.kernel.org

Before sending: add Signed-off-by with a real name and address.
