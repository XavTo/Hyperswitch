FROM docker pull juspaydotin/hyperswitch-router:2026.07.24.0-standalone
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash postgresql-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY config/docker_compose.toml /local/config/docker_compose.toml
COPY migrations /local/migrations
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
