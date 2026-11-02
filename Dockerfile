FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.17.0
ARG ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY cells cells
RUN /opt/zig/zig build -Doptimize=ReleaseSafe -Dcpu=baseline

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/zig-out zig-out
COPY zeldi.json zeldi.json
CMD ["/app/zig-out/bin/zeldi", "dev", "--live", "--listen", "0.0.0.0", "--data", "/data", "--config", "zeldi.json", "--operator-port", "9090"]
