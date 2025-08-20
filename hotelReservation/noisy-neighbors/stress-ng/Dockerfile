FROM ubuntu:22.04

# Install minimal runtime dependencies  
RUN apt-get update && apt-get install -y \
    stress-ng \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Set default entrypoint
ENTRYPOINT ["stress-ng"]
CMD ["--help"]