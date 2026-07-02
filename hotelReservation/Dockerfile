FROM golang:1.21 as builder

RUN apt-get update && apt-get install -y gcc

WORKDIR /workspace

COPY go.sum go.sum
COPY go.mod go.mod
COPY vendor/ vendor/

COPY cmd/ cmd/
COPY dialer/ dialer/
COPY interceptor/ interceptor/
COPY registry/ registry/
COPY services/ services/
COPY tls/ tls/
COPY tracing/ tracing/
COPY tune/ tune/

COPY config.json config.json

# Build ALL three perf static libs: windowed_sampler.go links
# -lperf_api_windowed and -lmsr_reader unconditionally (no build tag), so every
# service binary needs them, not just libperf_api.a. Missing these caused
# "/usr/bin/ld: cannot find -lperf_api_windowed / -lmsr_reader" at go install.
WORKDIR /workspace/services/perf
RUN gcc -std=c11 -c perf_api.c -o perf_api.o && ar rcs libperf_api.a perf_api.o \
    && gcc -O2 -Wall -fPIC -c perf_api_windowed.c -o perf_api_windowed.o \
    && ar rcs libperf_api_windowed.a perf_api_windowed.o \
    && gcc -O2 -Wall -fPIC -c msr_reader.c -o msr_reader.o \
    && ar rcs libmsr_reader.a msr_reader.o

WORKDIR /workspace

ENV CGO_ENABLED=1 \
    CGO_LDFLAGS="-L/workspace/services/perf -lperf_api" \
    CGO_CFLAGS="-I/workspace/services/perf"

RUN GOOS=linux GO111MODULE=on go install -mod=vendor ./cmd/...