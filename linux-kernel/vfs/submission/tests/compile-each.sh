#!/bin/bash
# compile-each.sh <range> -- check out each commit in <range> and compile the
# objects it touches (plus representative users of any header it touches).
# Object builds only: nice -n 19 make O=build -j4 W=1 <obj>.
set -u
cd /usr/src/sub-vfs || exit 1
range="$1"
start=$(git rev-parse --abbrev-ref HEAD)
for c in $(git rev-list --reverse "$range"); do
	git checkout -q "$c" || exit 1
	objs=""
	for f in $(git diff-tree --no-commit-id --name-only -r "$c"); do
		case "$f" in
		*.c) objs="$objs ${f%.c}.o" ;;
		include/linux/fs.h) objs="$objs fs/inode.o fs/open.o fs/stat.o fs/file_table.o mm/filemap.o" ;;
		include/linux/security.h) objs="$objs security/security.o fs/file_table.o" ;;
		include/linux/lsm_hook_defs.h) objs="$objs security/security.o security/selinux/hooks.o security/bpf/hooks.o kernel/bpf/bpf_lsm.o" ;;
		include/linux/bpf_lsm.h) objs="$objs kernel/bpf/trampoline.o kernel/bpf/bpf_lsm.o" ;;
		include/linux/stat.h) objs="$objs fs/stat.o" ;;
		fs/internal.h) objs="$objs fs/namei.o fs/open.o fs/stat.o" ;;
		security/lsm.h) objs="$objs security/lsm_init.o security/security.o" ;;
		esac
	done
	objs=$(echo $objs | tr ' ' '\n' | sort -u | tr '\n' ' ')
	echo "=== $(git log -1 --format='%h %s' $c)"
	[ -z "$objs" ] && { echo "    (no C objects touched)"; continue; }
	for o in $objs; do
		out=$(nice -n 19 make O=build -j4 W=1 "$o" 2>&1)
		rc=$?
		w=$(echo "$out" | grep -c -E "warning:|error:")
		printf '    %-34s rc=%d warnings/errors=%d\n' "$o" "$rc" "$w"
		[ "$rc" -ne 0 -o "$w" -ne 0 ] && echo "$out" | grep -E -A3 "warning:|error:" | head -20 | sed 's/^/        /'
	done
done
git checkout -q "$start"
