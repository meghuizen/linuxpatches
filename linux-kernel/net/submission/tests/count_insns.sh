#!/bin/bash
# count_insns.sh <objdump> <obj> <func>: static instruction count of one function,
# excluding nop padding and endbr64
$1 -d --no-show-raw-insn "$2" | awk -v f="<$3>:" '
	$2 == f { on = 1; next }
	on && /^$/ { exit }
	on && /^ *[0-9a-f]+:/ { if ($0 ~ /\tnop|\tendbr|\tc\.nop|xchg   %ax,%ax/) next; n++ }
	END { print n + 0 }'
