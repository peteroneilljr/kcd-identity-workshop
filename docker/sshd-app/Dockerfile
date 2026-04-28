FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-server ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Local unix accounts that map 1:1 to Keycloak identities. SSH cert principals
# (set by ssh-ca to preferred_username) must match the per-user principals file.
RUN useradd -m -s /bin/bash alice && \
    useradd -m -s /bin/bash bob  && \
    mkdir -p /etc/ssh/auth_principals && \
    echo "alice" > /etc/ssh/auth_principals/alice && \
    echo "bob"   > /etc/ssh/auth_principals/bob   && \
    chmod 644 /etc/ssh/auth_principals/*

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22

CMD ["/usr/local/bin/entrypoint.sh"]
