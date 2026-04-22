#!/bin/sh
exec valgrind \
    --tool=callgrind \
    --callgrind-out-file=/etc/prof-results/callgrind.out.%p \
    --collect-jumps=yes \
    freeradius -f -l stdout -S resources.talloc_skip_cleanup=yes
