FROM ubuntu:22.04

# Install minimal runtime dependencies  
RUN apt-get update && apt-get install -y \
    libc6 \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Copy existing stress-ng binary
COPY stress-ng /usr/bin/stress-ng
RUN chmod +x /usr/bin/stress-ng

# Set default entrypoint
ENTRYPOINT ["stress-ng"]
CMD ["--help"]