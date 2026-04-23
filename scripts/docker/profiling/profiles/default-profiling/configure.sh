#!/bin/sh
./configure \
    --enable-developer \
    --disable-verify-ptr \
    --with-raddbdir=/etc/freeradius \
    CFLAGS="-g3 -O1 -fno-omit-frame-pointer" \
    LDFLAGS="-fno-omit-frame-pointer"
