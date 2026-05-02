# ── Build stage ────────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Download dependencies first (cached layer unless go.mod changes).
COPY go.mod ./
# GONOSUMDB / GOFLAGS allow building without a committed go.sum.
# Run `go mod tidy` locally to generate go.sum for reproducible pinned builds.
ENV GONOSUMDB="*" GOFLAGS="-mod=mod"
RUN go mod download 2>/dev/null || true

COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o sync-server .

# ── Runtime stage ──────────────────────────────────────────────────────────────
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app
COPY --from=builder /build/sync-server .

RUN mkdir /data
VOLUME /data

ENV PORT=8080
ENV DB_PATH=/data/sync.db
# Optional: set JWT_SECRET to keep sessions alive across container restarts.
# If unset a random secret is persisted in the database on first run.

EXPOSE 8080
CMD ["./sync-server"]
