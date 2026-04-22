FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN echo "slapd slapd/password1 password adminpassword" | debconf-set-selections \
 && echo "slapd slapd/password2 password adminpassword" | debconf-set-selections \
 && echo "slapd slapd/domain string example.com" | debconf-set-selections \
 && echo "slapd shared/organization string Example" | debconf-set-selections \
 && apt-get update \
 && apt-get install -y --no-install-recommends slapd ldap-utils \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/docker/profiling/openldap/users.ldif /etc/ldap/users.ldif

# Pre-populate the database during the build so the container is ready on start
RUN slapd -h "ldapi:///" -u openldap -g openldap & \
    for i in $(seq 1 30); do \
        ldapsearch -x -H ldapi:/// -D "cn=admin,dc=example,dc=com" \
            -w adminpassword -b "dc=example,dc=com" > /dev/null 2>&1 && break; \
        sleep 1; \
    done && \
    ldapadd -x -H ldapi:/// -D "cn=admin,dc=example,dc=com" \
        -w adminpassword -f /etc/ldap/users.ldif && \
    kill "$(pidof slapd)" && \
    sleep 2

EXPOSE 389

CMD ["slapd", "-h", "ldap:///", "-u", "openldap", "-g", "openldap", "-d", "0"]
