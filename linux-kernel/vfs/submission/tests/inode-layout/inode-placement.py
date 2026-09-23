#!/usr/bin/env python3
"""
Model struct inode placements for the i_readcount false-sharing question.

Input: pahole output for struct inode (top-level members, x86-64).
For every candidate layout obtained by moving one block of fields to
another position (fields keep their natural alignment), and for every
start offset a in {0,8,...,56} of struct inode modulo 64, compute:

  stat_lines  cachelines holding fields stat() reads
  open_lines  cachelines holding fields an O_RDONLY open+close touches
  separated   True if the line(s) holding i_readcount hold no field
              that open/close/stat/path walk read on other CPUs

and check the three requirements against the base layout:
  R1 stat_lines(new) <= stat_lines(base)   for every a
  R2 open_lines(new) <= open_lines(base)   for every a
  R3 separated(new)                        for every a
plus size(new) <= size(base).

Access sets (x86-64, CONFIG_FILE_LOCKING, O_LARGEFILE forced on 64-bit):
  open/close reads: i_mode i_opflags i_flags i_acl (no_acl_inode() in
    acl_permission_check()) i_uid i_gid i_op i_sb i_mapping i_security
    i_fop (do_dentry_open) i_flctx (break_lease, locks_remove_posix)
    i_data.host (file_ra_state_init) i_data.a_ops (FMODE_CAN_ODIRECT)
    i_data.wb_err (filemap_sample_wb_err)
  open/close writes: i_readcount (i_readcount_inc/dec)
  stat reads: i_mode i_flags i_uid i_gid i_op i_sb i_security i_ino
    i_nlink i_rdev i_size i_*time_sec i_*time_nsec i_blkbits i_blocks
"""
import re, sys, itertools

def fname(s):
    s = re.sub(r'/\*.*?\*/', '', s)
    s = re.sub(r'__attribute__.*;', ';', s)
    m = re.search(r'\(\*\s*(\w+)\)', s)
    if m: return m.group(1)
    return re.findall(r'(\w+)\s*;', s)[0]

def parse(path):
    fields = []
    depth = 0
    union = None
    for l in open(path):
        s = l.strip()
        if s.startswith('struct inode {'):
            continue
        m = re.search(r'/\*\s+(\d+)\s+(\d+)\s+\*/', l)
        if s.startswith('union {'):
            depth += 1; union = []
            continue
        if s.startswith('}') and depth:
            depth -= 1
            off, size = int(m.group(1)), int(m.group(2))
            name = '|'.join(union)
            fields.append([name, off, size])
            union = None
            continue
        if m and depth == 0:
            fields.append([fname(s), int(m.group(1)), int(m.group(2))])
        elif m and depth:
            union.append(fname(s))
    return fields

def align_of(name, size):
    if size >= 8: return 8
    return size

def relayout(order):
    off = 0; out = {}
    for name, size in order:
        a = align_of(name, size)
        off = (off + a - 1) // a * a
        out[name] = (off, size)
        off += size
    return out, (off + 7) // 8 * 8

def key(fields, short):
    for n, _, _ in fields:
        if short in n.split('|'): return n
    raise KeyError(short)

OPEN_R = ['i_mode','i_opflags','i_flags','i_acl','i_uid','i_gid','i_op','i_sb',
          'i_mapping','i_security','i_fop','i_flctx']
DATA_R = [(0,8),(96,8),(112,4)]           # i_data.host, a_ops, wb_err
STAT_R = ['i_mode','i_flags','i_uid','i_gid','i_op','i_sb','i_security','i_ino',
          'i_nlink','i_rdev','i_size','i_atime_sec','i_mtime_sec','i_ctime_sec',
          'i_atime_nsec','i_mtime_nsec','i_ctime_nsec','i_blkbits','i_blocks']
WRITE = ['i_readcount']
# fields other CPUs read on hot paths (open, stat, walk, read(2)); i_pages
# is read by every page cache lookup
READ_HOT = OPEN_R + STAT_R + ['i_pages']

def lines(ranges, a):
    s = set()
    for off, size in ranges:
        for b in (off, off + size - 1):
            s.add((a + b) // 64)
        for L in range((a + off) // 64, (a + off + size - 1) // 64 + 1):
            s.add(L)
    return s

def ranges_for(lay, names, fields):
    r = []
    for sname in names:
        r.append(lay[key(fields, sname)])
    return r

def evaluate(lay, fields):
    d = lay[key(fields, 'i_data')][0]
    open_r = ranges_for(lay, OPEN_R, fields) + [(d + o, s) for o, s in DATA_R]
    w = ranges_for(lay, WRITE, fields)
    stat_r = ranges_for(lay, STAT_R, fields)
    hot = ranges_for(lay, [x for x in READ_HOT if x != 'i_pages'], fields) + \
          [(d + o, s) for o, s in DATA_R] + [(d + 8, 16)]
    res = {}
    for a in range(0, 64, 8):
        wl = lines(w, a)
        sep = not (wl & lines(hot, a))
        res[a] = (len(lines(stat_r, a)), len(lines(open_r + w, a)), sep)
    return res

def main():
    fields = parse(sys.argv[1])
    names = [(n, s) for n, _, s in fields]
    base, bsize = relayout(names)
    b = evaluate(base, fields)
    print('base size', bsize)
    print('a   stat open separated')
    for a in b: print(f'{a:2d}  {b[a][0]:4d} {b[a][1]:4d} {b[a][2]}')
    # candidate blocks to move
    blocks = {
        'counters': ['i_count', 'i_dio_count', 'i_writecount', 'i_readcount'],
        'readcount+writecount': ['i_writecount', 'i_readcount'],
        'readcount': ['i_readcount'],
        'fop+flctx': [key(fields, 'i_fop'), 'i_flctx'],
    }
    best = []
    for bname, blk in blocks.items():
        blk = [key(fields, x) if x not in dict(names) else x for x in blk]
        rest = [x for x in names if x[0] not in blk]
        moved = [x for x in names if x[0] in blk]
        for pos in range(len(rest) + 1):
            order = rest[:pos] + moved + rest[pos:]
            lay, size = relayout(order)
            if size > bsize: continue
            r = evaluate(lay, fields)
            r1 = all(r[a][0] <= b[a][0] for a in r)
            r2 = all(r[a][1] <= b[a][1] for a in r)
            r3 = all(r[a][2] for a in r)
            nsep = sum(r[a][2] for a in r)
            extra_open = sum(max(0, r[a][1] - b[a][1]) for a in r)
            extra_stat = sum(max(0, r[a][0] - b[a][0]) for a in r)
            after = rest[pos - 1][0] if pos else '(start)'
            best.append((r1 and r2 and r3, nsep, -extra_open, -extra_stat, bname, after, r))
    ok = [x for x in best if x[0]]
    print('\nlayouts meeting R1+R2+R3 for all 8 offsets:', len(ok))
    for x in ok: print('  move', x[4], 'after', x[5])
    print('\nper block: placements separating i_readcount at all 8 offsets,'
          ' and the fewest extra open lines among them (summed over a):')
    for bname in blocks:
        cand = [x for x in best if x[4] == bname and x[1] == 8]
        if not cand:
            print(f'  {bname:22s} none'); continue
        c = max(cand, key=lambda x: (x[2], x[3]))
        print(f'  {bname:22s} {len(cand):3d} placements; best: after {c[5]}: '
              f'extra open lines {-c[2]}, extra stat lines {-c[3]}')
        for a in c[6]:
            print(f'      a={a:2d} stat {b[a][0]}->{c[6][a][0]} open {b[a][1]}->{c[6][a][1]}')
    print('\nper block: placements with no extra stat or open line at any offset,'
          ' and how many offsets they separate:')
    for bname in blocks:
        cand = [x for x in best if x[4] == bname and x[2] == 0 and x[3] == 0]
        m = max((x[1] for x in cand), default=None)
        print(f'  {bname:22s} {len(cand):3d} placements; max offsets separated: {m}')
        for x in cand:
            if x[1] == m and m:
                print(f'      after {x[5]}: separated at a in '
                      f'{[a for a in x[6] if x[6][a][2]]}')
main()

if len(sys.argv) > 2:
    # compare an actual second layout (e.g. pahole of a patched build)
    f0 = parse(sys.argv[1]); f1 = parse(sys.argv[2])
    l0 = {n: (o, s) for n, o, s in f0}; l1 = {n: (o, s) for n, o, s in f1}
    e0 = evaluate(l0, f0); e1 = evaluate(l1, f1)
    print(f'\n{sys.argv[2]} vs {sys.argv[1]}:')
    print('a   stat      open      i_readcount separated')
    for a in e0:
        print(f'{a:2d}  {e0[a][0]}->{e1[a][0]}      {e0[a][1]}->{e1[a][1]}      {e0[a][2]}->{e1[a][2]}')
