#!/bin/sh
exec valgrind \
    --tool=callgrind \
    --callgrind-out-file=/etc/prof-results/callgrind.out.%p \
    --trace-children=yes \
    --separate-threads=yes \
    --dump-instr=yes \
    --collect-jumps=yes \
    --cache-sim=yes \
    --branch-sim=yes \
    freeradius -f -l stdout -S resources.talloc_skip_cleanup=yes
