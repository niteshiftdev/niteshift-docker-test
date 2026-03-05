FROM golang:1.22 AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go .
RUN CGO_ENABLED=0 go build -o /healthcheck main.go

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /healthcheck /healthcheck
EXPOSE 9090
CMD ["/healthcheck"]
