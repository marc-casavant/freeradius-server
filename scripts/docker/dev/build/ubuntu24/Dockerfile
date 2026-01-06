# syntax=docker/dockerfile:1.6

# IMPORTANT: For development testing use only. Do not use as a base for production images.
#
# Build example:
# docker build --no-cache -t <your-image-name> -f scripts/docker/dev/build/ubuntu24/Dockerfile .
#

ARG from=ubuntu:24.04
FROM ${from} AS build

ARG DEBIAN_FRONTEND=noninteractive

#
#  Install build dependencies
#
RUN apt-get update && \
    apt-get install -y software-properties-common gnupg2 procps && \
    apt-get clean && \
    rm -r /var/lib/apt/lists/*


RUN apt-get update && \
    # Development utilities
    apt-get install -y devscripts equivs git quilt rsync vim less && \
    # Compilers
    apt-get install -y g++ llvm clang lldb && \
    # eapol_test dependencies
    apt-get install -y libnl-3-dev libnl-genl-3-dev && \
    # CMake for building libkqueue
    apt-get install -y cmake && \
    # RADIUS server build dependencies
    apt-get install -y libtalloc-dev && \
    # OpenSSL development files
    apt-get install -y libssl-dev && \
    # Brotli development files
    apt-get install -y --no-install-recommends libbrotli-dev && \
    # GUI readline utility
    apt-get install -y --no-install-recommends libreadline-dev libncurses-dev && \
    rm -rf /var/lib/apt/lists/*

#
#  Build and install libkqueue > 2.6.3 from source
#
COPY scripts/docker/dev/build/ubuntu24/patch-libkqueue-soname-0.cmake /work/patch-libkqueue-soname-0.cmake
COPY scripts/docker/dev/build/ubuntu24/build_libkqueue_deb.sh /work/build_libkqueue_deb.sh
RUN chmod +x /work/build_libkqueue_deb.sh && \
    /work/build_libkqueue_deb.sh && \
    apt-get update && \
    apt-get install -y /repo/pool/libkqueue0_*.deb /repo/pool/libkqueue-dev_*.deb && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /work /repo/pool/libkqueue*.deb

#
#  PLACEHOLDER FOR DOCUMENTATION BUILD DEPENDENCIES
#

#  - doxygen & JSON.pm
#RUN apt-get install -y doxygen graphviz libjson-perl
#  - antora (npm needed)
#RUN curl -sL https://deb.nodesource.com/setup_20.x | bash -
#RUN apt-get install -y nodejs
#RUN npm i -g @antora/cli@3.1.7 @antora/site-generator-default@3.1.7
#  - pandoc
#WORKDIR /tmp
#RUN curl -OL $(curl -s https://api.github.com/repos/jgm/pandoc/releases/latest | grep "browser_download_url.*deb" | cut -d '"' -f 4)
#RUN apt-get install -y ./pandoc-*.deb
#  - asciidoctor
#RUN apt-get install -y ruby-dev
#RUN gem install asciidoctor

#
#  Setup a src dir in /usr/local
#
RUN mkdir -p /usr/local/src/repositories
WORKDIR /usr/local/src/repositories

#
#  Shallow clone the FreeRADIUS source
#
WORKDIR /usr/local/src/repositories
RUN git clone --depth 1 --single-branch --branch master https://github.com/FreeRADIUS/freeradius-server.git

#
#  Configure build and install FreeRADIUS V4
#
#  NOTE:
#   --disable-verify-ptr is used to performance impacting macros
#
#   --prefix, --exec-prefix, --sysconfdir, --localstatedir, --sbindir set to be compatible
#   with test framework configurations.
#
WORKDIR freeradius-server
RUN ./configure \
      --disable-verify-ptr \
      --prefix=/usr \
      --exec-prefix=/usr \
      --sysconfdir=/etc \
      --localstatedir=/var \
      --sbindir=/usr/sbin \
 && make -j"$(nproc)" \
 && make install

#
# Create docker-entrypoint.sh script
#
WORKDIR /
RUN cat > docker-entrypoint.sh <<'EOF'
#!/bin/sh
set -e

# this if will check if the first argument is a flag
# but only works if all arguments require a hyphenated flag
# -v; -SL; -f arg; etc will work, but not arg1 arg2
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
    set -- freeradius "$@"
fi

# check for the expected command
if [ "$1" = 'freeradius' ]; then
    shift
    exec freeradius -f "$@"
fi

# many people are likely to call "radiusd" as well, so allow that
if [ "$1" = 'radiusd' ]; then
    shift
    exec freeradius -f "$@"
fi

# else default to run whatever the user wanted like "bash" or "sh"
exec "$@"

EOF

RUN chmod +x docker-entrypoint.sh

#
# Soft links for radiusd and freeradius to be in PATH
#
RUN ln -s /usr/sbin/radiusd /usr/local/bin/radiusd
RUN ln -s /usr/sbin/radiusd /usr/local/bin/freeradius

#
# Link /etc/freeradius to /etc/raddb similarly to how it's
# done in the deb builds.
#
RUN ln -s /etc/freeradius /etc/raddb

# Update radiusd.conf to set name = freeradius.  This is to ensure the server doesn't complain
# that freeradius.conf is not found when started with "freeradius" command.
RUN cp /etc/raddb/radiusd.conf /etc/raddb/freeradius.conf
RUN sed -i 's/^name = radiusd$/name = freeradius/' /etc/raddb/freeradius.conf

EXPOSE 1812/udp 1813/udp
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["freeradius"]
