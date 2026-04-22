ARG from=CB_IMAGE
FROM ${from}

# Copy profiling profile scripts into the container
COPY scripts/docker/profiling/profiles/PROFILE_NAME /profiling

RUN /profiling/configure.sh
RUN make
RUN make install

# Make sure freeradius can also be used to run server
RUN ln -s /usr/local/sbin/radiusd /usr/local/sbin/freeradius

WORKDIR /
COPY scripts/docker/etc/docker-entrypoint.sh.PKG_TYPE docker-entrypoint.sh
RUN chmod +x docker-entrypoint.sh

EXPOSE 1812/udp 1813/udp
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/profiling/start.sh"]
