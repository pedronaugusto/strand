# strand — the Linux image `ci/linux.sh` runs the suite in.
#
# Debian plus one Zig tarball, pinned to the version build.zig.zon asks for,
# and nothing else: the package has no dependency beyond `std`, so an image
# that needs a package manager would be an image proving the wrong thing.
#
#   docker build -f ci/linux.Dockerfile -t strand-zig-0.16.0 ci
#
# The architecture is whatever the host is, so this works on an arm64 laptop
# and on an x86_64 runner without being told which.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
ARG ZIG=0.16.0
RUN set -e; arch=$(uname -m); \
    for name in "zig-${arch}-linux-${ZIG}" "zig-linux-${arch}-${ZIG}"; do \
      if curl -fsSL "https://ziglang.org/download/${ZIG}/${name}.tar.xz" -o /tmp/zig.tar.xz; then break; fi; done; \
    mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
WORKDIR /src
