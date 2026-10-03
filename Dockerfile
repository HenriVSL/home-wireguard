# The WireGuard data path runs in the host kernel; this image only carries the
# userspace tools that configure it plus a small management page.
# Rebuilt weekly in CI from fresh bases to pick up Alpine and Go fixes.
FROM golang:alpine AS web
WORKDIR /src
COPY web/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /wg-web . && go vet ./...

FROM alpine:3

RUN apk add --no-cache bash iproute2 iptables ip6tables libqrencode-tools tzdata wireguard-tools

# Shown on the status page. Set by CI; local builds show "dev".
ARG VERSION=dev
ARG COMMIT=
ARG REPO=
RUN mkdir -p /etc/home-wireguard && printf '{"version":"%s","commit":"%s","repo":"%s","built":"%s"}\n' \
      "$VERSION" "$COMMIT" "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/home-wireguard/version.json

COPY rootfs/ /
COPY --from=web /wg-web /usr/local/bin/wg-web
RUN chmod 755 /usr/local/bin/*

VOLUME /data
EXPOSE 51820/udp 8080/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --start-interval=1s \
  CMD /usr/local/bin/healthcheck

ENTRYPOINT ["/usr/local/bin/entrypoint"]
