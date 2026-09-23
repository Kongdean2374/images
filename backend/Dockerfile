# Build with HTTP/3 support; use --build-arg TAGS= for the dependency-free build.
FROM golang:1.24-alpine AS build
ARG TAGS=http3
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -tags "$TAGS" -trimpath -ldflags "-s -w" -o /chainet-server ./cmd/chainet-server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /chainet-server /chainet-server
# 8080 HTTP/1.1+h2c · 8443 HTTPS h2 (tcp) + h3 (udp) · 9001 UDP echo
EXPOSE 8080/tcp 8443/tcp 8443/udp 9001/udp
ENTRYPOINT ["/chainet-server"]
