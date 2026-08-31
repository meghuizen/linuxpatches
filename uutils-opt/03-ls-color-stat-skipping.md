# Fix 3 — Skip per-entry stat in `ls --color` when the color config doesn't need it

**Target repository:** `uutils/coreutils`, `src/uu/ls/src/colors.rs` (+ the `lscolors` crate it delegates to)
**What this fix does, in one sentence:** teach `ls` to notice when the active `LS_COLORS` configuration only uses information `d_type` already provides (directory, symlink, extension), and in that case color every entry without issuing a single `stat` — matching an optimization GNU ls has had for years.

| | |
|---|---|
| Pattern to fix | `ls --color` (without `-l`) stats every entry to color it |
| Replacement | One up-front analysis of `LS_COLORS`; per-entry stat only when mode-dependent styles are actually configured |
| Effort | Moderate — one decision function + threading it through; possibly a small `lscolors`-crate contribution |
| Risk | Low-medium — coloring differences are visible and GNU-diffable |
| Line refs | As of shallow clone of master, 2026-08-31 |

---

## 1. Background: why coloring stats everything today

Coloring an entry can depend on two different kinds of information:

| Style class | Examples in `LS_COLORS` | Needs |
|---|---|---|
| Type + name based | `di` (dir), `ln` (symlink), `pi`, `so`, `*.tar=...` extensions | **`d_type` + the name — free** |
| Mode/attribute based | `ex` (executable), `su`/`sg` (setuid/setgid), `st`/`tw`/`ow` (sticky, other-writable), `ca` (capabilities) | **`stat` (mode bits) per entry** |

Because *some* configurations need mode bits, the simple implementation stats *every* entry under *every* configuration. That is where uutils is today: `colors.rs:232` (`apply_style_based_on_metadata`) routes styling through `style_for_path_with_metadata(&path.p_buf, md_option)` (`colors.rs:241`), and the metadata is fetched to feed it — even when the user's palette never looks at a mode bit.

GNU ls analyzes the palette once at startup: if no mode-dependent entries are active, it colors from the dirent type alone and skips the stat storm. Plain `ls --color` on a big directory then costs the same as plain `ls`. That is the parity gap this fix closes.

## 2. The fix shape

1. **Startup analysis:** after parsing `LS_COLORS`, compute one boolean: *does any active style require mode/attribute data?* (`ex`, `su`, `sg`, `st`, `tw`, `ow`, `ca`, and dereference-dependent symlink coloring like `ln=target`). The `colors.rs:359-376` region already shows styling from `file_type()` alone works for the dir/link/file cases.
2. **Per-entry decision:** if the boolean is false, style from `DirEntry::file_type()` + name (both free — see Fix 2) and *never touch* `PathData::metadata()`. If true, current behavior stands.
3. **Crate boundary:** uutils delegates to the `lscolors` crate, whose `style_for_path_with_metadata(path, Option<&Metadata>)` already accepts `None` — the type-based subset works today by passing `None`. What may need a small upstream contribution to `lscolors` (github.com/sharkdp/lscolors) is the *analysis* half: "does this parsed palette contain metadata-dependent styles?" — a one-method addition that benefits every `lscolors` consumer (`fd`, `lsd`, `eza` all face the same question).

Note the interaction with the lazy `OnceCell` design (`ls.rs:910-950`): the laziness already means "don't stat unless someone asks" — this fix makes coloring *stop asking*. The two compose; neither replaces the other.

## 3. Upstreaming notes

Two PRs, possibly three: (a) the `lscolors` crate method (small, generally useful, sharkdp's repos review fast); (b) the uutils `ls` change using it; optionally (c) a fallback local implementation in uutils if the crate PR stalls. The GNU parity argument carries the uutils PR — cite GNU ls behavior, and include the default-`LS_COLORS` case in the analysis: **stock distro palettes set `ex`**, so the fast path fires mainly for `--color` with `-F`-less minimal palettes and for users who tuned `LS_COLORS`. Say this honestly in the PR: the win is conditional on the palette, the cost when it doesn't fire is one boolean check.

## 4. Effectiveness test — did it actually work?

```bash
cd /tmp && mkdir lst && cd lst && for i in $(seq 5000); do : > f$i; done
# Palette WITHOUT mode-dependent styles - the fast path must fire:
LS_COLORS="di=34:ln=36:*.txt=32" strace -c ./target/release/ls --color=always > /dev/null
# Palette WITH ex= - the fast path must NOT fire:
LS_COLORS="di=34:ex=31" strace -c ./target/release/ls --color=always > /dev/null
```

| Gate | Threshold | Meaning |
|---|---|---|
| stat-family calls, mode-free palette | ~0 (vs ~5000 before) | The analysis + skip works |
| stat-family calls, `ex=` palette | Unchanged from before | No correctness shortcut taken |
| Byte-identical output vs GNU ls | `diff <(ls --color=always) <(uutils ls --color=always)` clean for both palettes, plus a tree containing setuid/sticky/exec files under a full default palette | Visible-output parity — the gate that matters for this fix |
| `ls --color` wall time, mode-free palette, 100k-entry directory | Approaches plain `ls` | The user-visible payoff |

**The honest failure mode:** shipping the skip while a default distro palette is active and calling the benchmark a win — default palettes contain `ex`, so the honest headline is "ls --color no longer pays for stats *the palette doesn't use*," not "ls --color is now always fast." Reviewers who run the default-palette case will find any overclaim immediately.
