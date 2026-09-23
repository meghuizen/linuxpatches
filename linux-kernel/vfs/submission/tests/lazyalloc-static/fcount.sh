#!/bin/bash
# fcount.sh obj func... : number of instructions in each function
o=$1; shift
for f in "$@"; do
  n=$(objdump -d --no-show-raw-insn --disassemble="$f" "$o" | grep -cE '^\s+[0-9a-f]+:\s')
  printf '%-22s %5d\n' "$f" "$n"
done
