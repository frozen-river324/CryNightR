FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates python3 && \
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
COPY . .
RUN chmod +x start.sh entrypoint.sh

ENV WALLET=ccx7BaYihWz3LkJmDT1sx76cafd9JKVyBikc55H8jqiAWe8QVzjpxi1PGBRGjc78DU6vhuR1yXMVFDwmWM1Mj1zs46mdtNSNMy
ENV POOL_URL=mine.conceal.network
ENV POOL_PORT=16055
ENV ALGO=cn/ccx
ENV TLS=false
ENV POOL_PASS=x
ENV DONATE=1

EXPOSE ${PORT:-8080}

ENTRYPOINT ["/app/entrypoint.sh"]
