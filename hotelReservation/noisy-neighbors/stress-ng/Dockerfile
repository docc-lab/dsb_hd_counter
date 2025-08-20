# Multi-stage build for smaller final image
FROM ubuntu:22.04 as builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    libaio-dev \
    libapparmor-dev \
    libattr1-dev \
    libbsd-dev \
    libcap-dev \
    libgcrypt20-dev \
    libkeyutils-dev \
    libsctp-dev \
    zlib1g-dev \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Download and build stress-ng from source
WORKDIR /tmp
RUN wget https://github.com/ColinIanKing/stress-ng/archive/refs/tags/V0.17.08.tar.gz \
    && tar -xzf V0.17.08.tar.gz \
    && cd stress-ng-0.17.08 \
    && make

# Final runtime image
FROM ubuntu:22.04

# Install only runtime dependencies
RUN apt-get update && apt-get install -y \
    libaio1 \
    libapparmor1 \
    libattr1 \
    libbsd0 \
    libcap2 \
    libgcrypt20 \
    libkeyutils1 \
    libsctp1 \
    zlib1g \
    procps \
    htop \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Copy stress-ng binary from builder
COPY --from=builder /tmp/stress-ng-0.17.08/stress-ng /usr/local/bin/

# Create non-root user for security
RUN useradd -r -s /bin/false stress-ng

# Set default entrypoint
ENTRYPOINT ["stress-ng"]

# Default command - can be overridden
CMD ["--help"]

# Labels for documentation
LABEL maintainer="your-email@domain.com"
LABEL description="Optimized stress-ng container for Kubernetes load testing"
LABEL version="0.17.08"