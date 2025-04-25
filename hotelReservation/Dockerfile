FROM golang:1.21 as builder

RUN apt-get update && apt-get install -y gcc

WORKDIR /workspace

COPY go.sum go.sum
COPY go.mod go.mod
COPY vendor/ vendor/

COPY cmd/ cmd/
COPY dialer/ dialer/
COPY registry/ registry/
COPY services/ services/
COPY tls/ tls/
COPY tracing/ tracing/
COPY tune/ tune/

COPY config.json config.json

RUN gcc -c services/perf/perf_api.c -o services/perf/perf_api.o && ar rcs perf_api.a services/perf/perf_api.o

RUN find . -name '*.go' && \
    CGO_ENABLED=0 GOOS=linux GO111MODULE=on go install -ldflags="-s -w" -mod=vendor ./cmd/...


