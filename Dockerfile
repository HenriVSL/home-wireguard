# The WireGuard data path runs in the host kernel; this image only carries the
# userspace tools that configure it. Rebuilt weekly in CI to pick up Alpine fixes.
FROM alpine:3

RUN apk add --no-cache bash iproute2 iptables ip6tables libqrencode-tools wireguard-tools

COPY rootfs/ /
RUN chmod 755 /usr/local/bin/*

VOLUME /data
EXPOSE 51820/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --start-interval=1s \
  CMD wg show wg0 listen-port >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint"]
