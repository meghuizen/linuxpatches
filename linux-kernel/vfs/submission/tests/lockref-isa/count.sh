#!/bin/bash
# count.sh <objdump> <obj> : instructions per function
OD=$1; OBJ=$2
$OD -d --no-show-raw-insn "$OBJ" | awk '
/^[0-9a-f]+ <.*>:$/ { if (f) printf "%-22s %d\n", f, n; f=$2; gsub(/[<>:]/,"",f); n=0; next }
/^ *[0-9a-f]+:\t/ { n++ }
END { if (f) printf "%-22s %d\n", f, n }'
