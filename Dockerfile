FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ARG XMRIG_VERSION=6.26.0
ARG ARCH=amd64

RUN curl -fsSL "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/xmrig-${XMRIG_VERSION}-linux-${ARCH}.tar.gz" \
    -o /tmp/xmrig.tar.gz && \
    mkdir -p /opt/xmrig && \
    tar -xzf /tmp/xmrig.tar.gz -C /opt/xmrig/ --strip-components=1 && \
    chmod +x /opt/xmrig/xmrig && \
    rm -f /tmp/xmrig.tar.gz

WORKDIR /app
COPY .env .
COPY start.sh .
RUN chmod +x start.sh

ENV WALLET=""
ENV POOL_URL=""
ENV POOL_PORT=""
ENV WORKER_NAME=""
ENV ALGO="cn/r"
ENV THREADS=""
ENV TLS="false"
ENV POOL_PASS="x"
ENV DONATE="1"

ENTRYPOINT ["/app/start.sh"]
