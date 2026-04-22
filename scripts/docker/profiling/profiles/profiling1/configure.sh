#!/bin/sh
./configure \
    --enable-developer \
    --disable-verify-ptr \
    --sysconfdir=/etc \
    CFLAGS="-g3 -O1 -fno-omit-frame-pointer" \
    LDFLAGS="-fno-omit-frame-pointer"
