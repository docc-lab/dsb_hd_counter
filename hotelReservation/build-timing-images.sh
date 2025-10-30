 #!/bin/bash

# Configuration for timing-enabled image building
REGISTRY="royno7"
IMAGE_PREFIX="service-withtimer"

# List of services that support timing integration
VALID_TIMING_SERVICES=("frontend" "geo" "profile" "rate" "recommendation" "reservation" "search" "user")

# Function to show usage
show_usage() {
    echo "Usage: $0 <service1 [service2 ...]|all> [tag]"
    echo ""
    echo "This script builds timing-enabled Docker images for specific services:"
    echo "  • Generates temporary Dockerfile with timing interceptor enabled"
    echo "  • Builds service-specific image (not single image for all services)"
    echo "  • Pushes to registry with timing-specific naming"
    echo ""
    echo "Arguments:"
    echo "  service    Build specific service(s) (${VALID_TIMING_SERVICES[*]})"
    echo "  all        Build all timing-enabled services"
    echo "  tag        Docker image tag (default: v1-withtimer)"
    echo ""
    echo "Examples:"
    echo "  $0 user v1-withtimer                     # Build only user service"
    echo "  $0 user frontend search v2-withtimer     # Build multiple services"
    echo "  $0 all v1-withtimer                      # Build all timing services"
    echo "  $0 all                                   # Build all (default tag)"
    echo ""
    echo "Valid timing services: ${VALID_TIMING_SERVICES[*]}"
    echo "Registry: ${REGISTRY}/<service>-${IMAGE_PREFIX}:<tag>"
    echo "Example output: royno7/user-service-perf:v1-withtimer"
}

# Function for consistent log formatting
log_info() {
    echo -e "\n[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "\n[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_success() {
    echo -e "\n[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Initialize array for tracking failed services
failed_services=()

# Function to validate if service supports timing
validate_timing_service() {
    local service=$1
    for valid_service in "${VALID_TIMING_SERVICES[@]}"; do
        if [[ "$service" == "$valid_service" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to generate timing-enabled Dockerfile for a specific service
generate_timing_dockerfile() {
    local service=$1
    local dockerfile_path="$(pwd)/Dockerfile.${service}-timing"
    
    cat > "$dockerfile_path" << EOF
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

WORKDIR /workspace

# Build the ${service} service with timing interceptor (no CGO needed)
ENV CGO_ENABLED=0
RUN GOOS=linux GO111MODULE=on go build -o build/${service} ./cmd/${service}/

# Runtime stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /root/

# Copy the binary from builder stage
COPY --from=builder /workspace/build/${service} ./${service}
COPY --from=builder /workspace/config.json .

# Make binary executable
RUN chmod +x ./${service}

# Environment variables for timing control
ENV ENABLE_TIMING=true
ENV STATS_FILE=timing_stats_${service}.json

EXPOSE 8081

CMD ["./${service}"]
EOF

    echo "$dockerfile_path"
}

# Function to build and push timing-enabled Docker image for a specific service
build_and_push_timing_image() {
    local service=$1
    local tag=$2
    local image_name="${REGISTRY}/${service}-${IMAGE_PREFIX}:${tag}"

    log_info "Building timing-enabled Docker image for $service"

    # Get architecture and decide platform
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            PLATFORM="linux/amd64"
            ;;
        aarch64|arm64)
            PLATFORM="linux/arm64"
            ;;
        armv7l)
            PLATFORM="linux/arm/v7"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            return 1
            ;;
    esac

    # Generate temporary Dockerfile
    log_info "Generating timing-enabled Dockerfile for $service"
    local dockerfile_path=$(generate_timing_dockerfile "$service")
    
    log_info "Building image: ${image_name}"
    log_info "Platform: ${PLATFORM}"
    log_info "Using Dockerfile: ${dockerfile_path}"
    
    # Use regular docker build (buildx seems to have issues)
    if ! sudo docker build --no-cache -t "${image_name}" -f "$dockerfile_path" .; then
        log_error "Docker build failed for $service"
        # Clean up temporary Dockerfile
        rm -f "$dockerfile_path"
        return 1
    fi
    
    # Push the image separately
    log_info "Pushing image: ${image_name}"
    if ! sudo docker push "${image_name}"; then
        log_error "Docker push failed for $service"
        # Clean up temporary Dockerfile
        rm -f "$dockerfile_path"
        return 1
    fi
    
    log_success "Image built and pushed successfully: ${image_name}"
    
    # Clean up temporary Dockerfile
    rm -f "$dockerfile_path"
    
    return 0
}

# Function to build multiple timing-enabled services
build_multiple_timing_services() {
    local services=("$@")
    local tag="${services[-1]}"  # Last argument is the tag
    unset 'services[-1]'        # Remove tag from services array
    local failed_services=()
    
    # Check if tag looks like a service name instead of a tag
    for valid_service in "${VALID_TIMING_SERVICES[@]}"; do
        if [[ "$tag" == "$valid_service" ]]; then
            # Last argument is actually a service, not a tag
            services+=("$tag")
            tag="v1-withtimer"  # Use default tag
            break
        fi
    done
    
    echo "=========================================="
    echo "Building Timing-Enabled Service Images"
    echo "Services: ${services[*]}"
    echo "Tag: $tag"
    echo "Registry: ${REGISTRY}"
    echo "=========================================="
    
    # Build each service individually
    for service in "${services[@]}"; do
        echo ""
        echo "Building timing image for $service"
        echo "----------------------------------------"
        
        if ! build_and_push_timing_image "$service" "$tag"; then
            log_error "Failed to build timing image for $service"
            failed_services+=("$service")
            continue
        fi
        
        echo " $service timing image built successfully"
        echo "   Image: ${REGISTRY}/${service}-${IMAGE_PREFIX}:${tag}"
    done
    
    echo ""
    echo "=========================================="
    echo "BUILD SUMMARY"
    echo "=========================================="
    
    if [ ${#failed_services[@]} -eq 0 ]; then
        echo " All timing images built successfully!"
        echo ""
        echo "Built images:"
        for service in "${services[@]}"; do
            echo "  - ${REGISTRY}/${service}-${IMAGE_PREFIX}:${tag}"
        done
        echo ""
        echo "To use these images in your experiment, update the TIMING_IMAGES array in data-collector.sh:"
        echo ""
        for service in "${services[@]}"; do
            echo "    [\"$service\"]=\"${REGISTRY}/${service}-${IMAGE_PREFIX}:${tag}\""
        done
        return 0
    else
        echo " Some services failed to build:"
        for failed_service in "${failed_services[@]}"; do
            echo "   - $failed_service"
        done
        echo ""
        echo "Please check the logs above for details."
        return 1
    fi
}

# Main execution starts here
log_info "Starting timing image build process"
cd "$(dirname "$0")" || { log_error "Failed to navigate to script directory"; exit 1; }

# Check for help or invalid arguments
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] || [[ -z "$1" ]]; then
    show_usage
    exit 0
fi

# Check if user wants to build all timing services
if [[ "$1" == "all" ]]; then
    TAG="${2:-v1-withtimer}"  # Default to v1-withtimer if no tag provided
    log_info "Building all timing services with tag: $TAG"
    build_multiple_timing_services "${VALID_TIMING_SERVICES[@]}" "$TAG"
    exit $?
fi

# Check if multiple services provided
if [[ $# -gt 1 ]]; then
    # Validate all provided services
    services_to_build=()
    tag="v1-withtimer"  # Default tag
    
    for arg in "$@"; do
        # Check if this argument is a valid timing service
        if validate_timing_service "$arg"; then
            services_to_build+=("$arg")
        else
            # Check if this looks like a tag (contains dots, numbers, or common tag patterns)
            if [[ "$arg" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                tag="$arg"
            else
                log_error "Invalid service: '$arg'"
                echo ""
                show_usage
                exit 1
            fi
        fi
    done
    
    if [[ ${#services_to_build[@]} -eq 0 ]]; then
        log_error "No valid timing services specified"
        echo ""
        show_usage
        exit 1
    fi
    
    log_info "Building timing images for: ${services_to_build[*]} with tag: $tag"
    build_multiple_timing_services "${services_to_build[@]}" "$tag"
    exit $?
fi

# Single service build
if ! validate_timing_service "$1"; then
    log_error "Service '$1' is not a valid timing service."
    echo ""
    show_usage
    exit 1
fi

log_info "Service '$1' validated successfully"

# Build single service timing image
build_multiple_timing_services "$1" "${2:-v1-withtimer}"
