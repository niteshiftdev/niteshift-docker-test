FROM golang:1.22-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go .
RUN CGO_ENABLED=0 go build -o /healthcheck main.go

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /healthcheck /healthcheck
EXPOSE 9090
CMD ["/healthcheck"]
