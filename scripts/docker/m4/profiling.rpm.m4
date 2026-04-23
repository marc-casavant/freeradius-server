ARG from=CB_IMAGE
FROM ${from}

# Copy profiling profile scripts into the container
COPY scripts/docker/profiling/profiles/PROFILE_NAME /profile

RUN /profile/configure.sh
RUN make
RUN make install

# Mirror the package image: both binary names and both config dir paths work
RUN ln -s /usr/local/sbin/radiusd /usr/local/sbin/freeradius
RUN ln -s /etc/freeradius/radiusd.conf /etc/freeradius/freeradius.conf
RUN ln -s /etc/freeradius /etc/raddb

WORKDIR /
COPY scripts/docker/etc/docker-entrypoint.sh.PKG_TYPE docker-entrypoint.sh
RUN chmod +x docker-entrypoint.sh

EXPOSE 1812/udp 1813/udp
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/profile/start.sh"]
