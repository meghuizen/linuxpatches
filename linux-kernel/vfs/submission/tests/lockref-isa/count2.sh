#!/bin/bash
# count2.sh <objdump> <obj>: instructions per global function, ignoring local .L labels
# and trailing alignment nops
$1 -d --no-show-raw-insn "$2" | awk '
/^[0-9a-f]+ <[^.].*>:$/ { flush(); f=$2; gsub(/[<>:]/,"",f); n=0; nops=0; next }
/^[0-9a-f]+ <\.L.*>:$/ { next }
/^ *[0-9a-f]+:\t/ { n++; if ($2 ~ /^(nop|nopw|nopl|xchg|c\.nop)$/ || $0 ~ /\tnop/) nops++; else nops=0 }
function flush() { if (f) c[f]=n-nops }
END { flush(); for (k in c) print k, c[k] }' | sort
