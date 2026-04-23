ARG from=CB_IMAGE
FROM ${from}

# Copy profiling profile scripts into the container
COPY scripts/docker/profiling/profiles/PROFILE_NAME /profile

#
#  Install profiling tools
#
RUN apt-get update && \
    apt-get install $APT_OPTS \
        libgoogle-perftools-dev \
        google-perftools \
        valgrind \
        heaptrack \
        psmisc \
        kcachegrind \
        kio \
        libkf5iconthemes5 \
        libkf5parts5 \
        libkf5textwidgets5 \
        libqt5gui5 \
        libqt5widgets5 && \
    apt-get clean && \
    rm -r /var/lib/apt/lists/*

#
#  Set up Ubuntu debug symbol repository and install OS library debug symbols.
#  These allow callgrind/valgrind to resolve system library calls (glibc,
#  OpenSSL, talloc, etc.) to named symbols instead of hex addresses.
#
RUN apt-get update && \
    apt-get install $APT_OPTS ubuntu-dbgsym-keyring && \
    printf 'deb http://ddebs.ubuntu.com OS_CODENAME main restricted universe multiverse\ndeb http://ddebs.ubuntu.com OS_CODENAME-updates main restricted universe multiverse\n' \
        > /etc/apt/sources.list.d/ddebs.list && \
    apt-get update && \
    apt-get install $APT_OPTS \
        libc6-dbg \
        libssl3t64-dbgsym \
        libtalloc2-dbgsym \
        libpcre2-8-0-dbgsym \
        libsqlite3-0-dbgsym && \
    apt-get clean && \
    rm -r /var/lib/apt/lists/*

#
#  Install FlameGraph scripts
#
RUN git clone --depth 1 https://github.com/brendangregg/FlameGraph /opt/flamegraph \
    && chmod +x /opt/flamegraph/*.pl /opt/flamegraph/*.sh

ENV PATH="/opt/flamegraph:${PATH}"

EXPOSE 1812/udp 1813/udp
CMD ["/bin/sh", "-c", "while true; do sleep 60; done"]
