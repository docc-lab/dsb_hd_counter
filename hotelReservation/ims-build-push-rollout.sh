#!/bin/bash

# Configuration
REGISTRY="docclabgroup"
IMAGE_NAME="hotelreservation"
TIMING_MODE=false
WINDOWED_MODE=false

# List of services that have kubernetes deployment files
VALID_SERVICES=("frontend" "geo" "profile" "rate" "recommendation" "reservation" "search" "user")

# Function to show usage
show_usage() {
    echo "Usage: $0 [--mode-timer] [--registry=REGISTRY] [--image-prefix=PREFIX] <service1 [service2 ...]|all> [tag]"
    echo ""
    echo "This script follows the working approach from kubernetes/scripts/:"
    echo "  • Builds a single 'hotelreservation' image (not per-service images)"
    echo "  • Updates deployment YAML files with new image"
    echo "  • Applies updated deployments to Kubernetes"
    echo ""
    echo "Options:"
    echo "  --mode-timer           Enable basic timing mode (timing only, no perf counters)"
    echo "  --mode-windowed        Enable windowed sampling mode (timing + perf counters)"
    echo "  --registry=REGISTRY    Set Docker registry (default: docclabgroup)"
    echo "  --image-prefix=PREFIX  Set image name prefix (default: hotelreservation)"
    echo ""
    echo "Arguments:"
    echo "  service    Deploy specific service(s) (${VALID_SERVICES[*]})"
    echo "  all        Deploy all valid services (NOT allowed in timing mode)"
    echo "  tag        Docker image tag (default: debug0.1)"
    echo ""
    echo "Examples:"
    echo "  $0 frontend debug0.2                                     # Deploy only frontend"
    echo "  $0 frontend geo profile debug0.1                         # Deploy multiple specific services"
    echo "  $0 all debug0.1                                          # Deploy all valid services"
    echo "  $0 --mode-timer search v1-timer                          # Deploy search with basic timing"
    echo "  $0 --mode-windowed search v1-windowed                    # Deploy search with windowed sampling"
    echo "  $0 --mode-windowed --registry=royno7 search v1-windowed  # Deploy to custom registry"
    echo "  $0 all                                                   # Deploy all (default tag)"
    echo ""
    echo "Valid services: ${VALID_SERVICES[*]}"
    echo "Registry: ${REGISTRY}/${IMAGE_NAME}"
    echo "Note: 'review' and 'attractions' do not have kubernetes deployment files"
    echo "Note: Timing mode only works with specific services, not 'all'"
    echo "Rollout timeout: 60 seconds per service"
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

# Function to validate if service is deployable
validate_service() {
    local service=$1
    for valid_service in "${VALID_SERVICES[@]}"; do
        if [[ "$service" == "$valid_service" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to get container name for kubectl set image
get_container_name_for_deployment() {
    local service=$1
    case $service in
        "user")
            echo "hotel-reserv-user"
            ;;
        "frontend")
            echo "hotel-reserv-frontend"
            ;;
        "search")
            echo "hotel-reserv-search"
            ;;
        "profile")
            echo "hotel-reserv-profile"
            ;;
        "rate")
            echo "hotel-reserv-rate"
            ;;
        "recommendation")
            echo "hotel-reserv-recommendation"
            ;;
        "reservation")
            echo "hotel-reserv-reservation"
            ;;
        "geo")
            echo "hotel-reserv-geo"
            ;;
        *)
            echo "hotel-reserv-$service"
            ;;
    esac
}

# Function to generate timing-enabled Dockerfile for a specific service
generate_timing_dockerfile() {
    local service=$1
    local mode=$2  # "timer" or "windowed"
    local dockerfile_path="$(pwd)/Dockerfile.${service}-${mode}"
    
    # Determine environment variables based on mode
    local env_vars=""
    if [[ "$mode" == "windowed" ]]; then
        env_vars="ENV ENABLE_WINDOWED_SAMPLING=true
ENV ITERATION_ID=1
ENV EXPERIMENT_DURATION=30
ENV WINDOW_INTERVAL_MS=100
ENV CPU_SET=0,1,2
ENV PERF_EVENTS=\"cycles,instructions,cache-misses\"
ENV OUTPUT_DIR=/data"
    else
        env_vars="ENV ENABLE_TIMING=true"
    fi
    
    cat > "$dockerfile_path" << EOF
FROM golang:1.21 as builder

RUN apt-get update && apt-get install -y gcc make binutils linux-perf

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

# Build perf_api static library for CGO
RUN gcc -c services/perf/perf_api.c -o services/perf/perf_api.o && \\
    ar rcs services/perf/libperf_api.a services/perf/perf_api.o

# Build perf_api_windowed static library for windowed sampling
RUN gcc -c services/perf/perf_api_windowed.c -o services/perf/perf_api_windowed.o && \\
    ar rcs services/perf/libperf_api_windowed.a services/perf/perf_api_windowed.o

# Build the ${service} service (CGO enabled for perf counters)
ENV CGO_ENABLED=1
RUN GOOS=linux GO111MODULE=on go build -o build/${service} ./cmd/${service}/

# Runtime stage - use Debian for glibc compatibility with CGO binaries
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates linux-perf && rm -rf /var/lib/apt/lists/*

# Create data directory for output
RUN mkdir -p /data && chmod 777 /data

WORKDIR /

# Copy the binary from builder stage to a PATH directory
COPY --from=builder /workspace/build/${service} /usr/local/bin/${service}
COPY --from=builder /workspace/config.json /config.json

# Ensure binary is executable
RUN chmod +x /usr/local/bin/${service}

# Environment variables for timing/sampling control
${env_vars}

EXPOSE 8081

# Use taskset to pin process to specific CPUs for accurate perf monitoring
# CPU_SET env var can be overridden at runtime
ENTRYPOINT ["sh", "-c", "if [ -n \"\$CPU_SET\" ]; then exec taskset -c \$CPU_SET /usr/local/bin/${service}; else exec /usr/local/bin/${service}; fi"]
EOF

    echo "$dockerfile_path"
}

# Function to build and push Docker image (single image for all services)
build_and_push_docker() {
    local tag=$1
    local service=$2
    local image_full_name="${REGISTRY}/${IMAGE_NAME}:${tag}"

    if [[ "$WINDOWED_MODE" == "true" ]]; then
        # In windowed sampling mode, build service-specific image
        image_full_name="${REGISTRY}/${service}-windowed:${tag}"
        log_info "Building windowed sampling Docker image for $service"
    elif [[ "$TIMING_MODE" == "true" ]]; then
        # In basic timing mode, build service-specific image
        image_full_name="${REGISTRY}/${service}-withtimer:${tag}"
        log_info "Building timing-enabled Docker image for $service"
    else
        log_info "Building and pushing single Docker image for all services"
    fi

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

    # Check if image already exists locally
    if ! sudo docker image inspect "${image_full_name}" >/dev/null 2>&1; then
        log_info "Building Docker image: ${image_full_name}"
        log_info "Platform: ${PLATFORM}"
        
        if [[ "$WINDOWED_MODE" == "true" ]]; then
            # Generate windowed sampling Dockerfile for specific service
            log_info "Generating windowed sampling Dockerfile for $service"
            local dockerfile_path=$(generate_timing_dockerfile "$service" "windowed")
            log_info "Using Dockerfile: ${dockerfile_path}"
            
            # Use regular docker build for windowed mode
            if ! sudo docker build --no-cache -t "${image_full_name}" -f "$dockerfile_path" .; then
                log_error "Docker build failed for $service"
                rm -f "$dockerfile_path"
                return 1
            fi
            
            # Push the image separately
            log_info "Pushing image: ${image_full_name}"
            if ! sudo docker push "${image_full_name}"; then
                log_error "Docker push failed for $service"
                rm -f "$dockerfile_path"
                return 1
            fi
            
            rm -f "$dockerfile_path"
        elif [[ "$TIMING_MODE" == "true" ]]; then
            # Generate basic timing Dockerfile for specific service
            log_info "Generating timing-enabled Dockerfile for $service"
            local dockerfile_path=$(generate_timing_dockerfile "$service" "timer")
            log_info "Using Dockerfile: ${dockerfile_path}"
            
            # Use regular docker build for timing mode
            if ! sudo docker build --no-cache -t "${image_full_name}" -f "$dockerfile_path" .; then
                log_error "Docker build failed for $service"
                rm -f "$dockerfile_path"
                return 1
            fi
            
            # Push the image separately
            log_info "Pushing image: ${image_full_name}"
            if ! sudo docker push "${image_full_name}"; then
                log_error "Docker push failed for $service"
                rm -f "$dockerfile_path"
                return 1
            fi
            
            rm -f "$dockerfile_path"
        else
            # Use docker buildx for better platform support (normal mode)
            if ! sudo docker buildx build --no-cache -t "${image_full_name}" \
                -f Dockerfile . --platform "${PLATFORM}" --push; then
                log_error "Docker build/push failed"
                return 1
            fi
        fi
        log_success "Image built and pushed successfully"
    else
        log_info "Image ${image_full_name} already exists locally"
        # Still push in case remote is outdated
        log_info "Pushing existing image to registry"
        if ! sudo docker push "${image_full_name}"; then
            log_error "Docker push failed"
            return 1
        fi
        log_success "Image pushed successfully"
    fi
}

# Function to check rollout status
check_rollout() {
    local service=$1
    local failed_rollouts=()
    local success=true

    log_info "Checking rollout status for updated service"

    log_info "Checking rollout status for $service"
    if ! kubectl rollout status "deployment/${service}" --timeout=30s; then
        log_error "Rollout failed for $service"
        failed_rollouts+=("$service")
        success=false
    else
        log_success "Rollout completed successfully for $service"
    fi

    if [ "$success" = false ]; then
        log_error "The following services failed to roll out: ${failed_rollouts[*]}"
        return 1
    fi

    log_success "Updated service rolled out successfully"
    return 0
}

# Function to update YAML files with new image
update_yaml_files() {
    local services=("$@")
    local tag="${services[-1]}"  # Last argument is the tag
    unset 'services[-1]'        # Remove tag from services array
    local image_full_name="${REGISTRY}/${IMAGE_NAME}:${tag}"
    local yaml_dir="kubernetes"
    local updated_files=()
    
    # Check if tag looks like a service name instead of a tag
    for valid_service in "${VALID_SERVICES[@]}"; do
        if [[ "$tag" == "$valid_service" ]]; then
            # Last argument is actually a service, not a tag
            services+=("$tag")
            tag="debug0.1"  # Use default tag
            image_full_name="${REGISTRY}/${IMAGE_NAME}:${tag}"
            break
        fi
    done
    
    if [[ "$WINDOWED_MODE" == "true" ]]; then
        log_info "Updating YAML files for windowed sampling mode (service-specific images)"
    elif [[ "$TIMING_MODE" == "true" ]]; then
        log_info "Updating YAML files for timing mode (service-specific images)"
    else
        log_info "Updating YAML files to use image: ${image_full_name}"
    fi
    
    # Update deployment YAML files for specified services
    for service in "${services[@]}"; do
        local deployment_file="${yaml_dir}/${service}/${service}-deployment.yaml"
        
        # Handle special cases where directory names differ
        case $service in
            "recommendation")
                deployment_file="${yaml_dir}/reccomend/recommendation-deployment.yaml"
                ;;
            "reservation")
                deployment_file="${yaml_dir}/reserve/reservation-deployment.yaml"
                ;;
        esac
        
        if [[ -f "$deployment_file" ]]; then
            log_info "Updating $deployment_file"
            
            # Create backup
            cp "$deployment_file" "${deployment_file}.backup"
            
            # Determine the correct image name for this service
            local service_image_name="${image_full_name}"
            if [[ "$WINDOWED_MODE" == "true" ]]; then
                service_image_name="${REGISTRY}/${service}-windowed:${tag}"
            elif [[ "$TIMING_MODE" == "true" ]]; then
                service_image_name="${REGISTRY}/${service}-withtimer:${tag}"
            fi
            
            # Update the image line using a comprehensive pattern that catches ANY existing image
            # This single pattern matches: registry/anything:tag or anything:tag and replaces the entire line
            sed -i '/^\s*image:/s|image:.*|image: '"${service_image_name}"'|g' "$deployment_file"
            
            # Verify the update worked
            if grep -q "${service_image_name}" "$deployment_file"; then
                log_success "Updated $deployment_file with image: ${service_image_name}"
                updated_files+=("$deployment_file")
            else
                log_error "Failed to update $deployment_file - image line not found or update failed"
                # Restore backup
                mv "${deployment_file}.backup" "$deployment_file"
            fi
        else
            log_error "Deployment file not found: $deployment_file"
        fi
    done
    
    if [[ ${#updated_files[@]} -gt 0 ]]; then
        log_success "Updated ${#updated_files[@]} YAML files"
        return 0
    else
        log_error "No YAML files were updated"
        return 1
    fi
}

# Function to deploy services (build + update YAML + apply)
deploy_multiple_services() {
    local services=("$@")
    local tag="${services[-1]}"  # Last argument is the tag
    unset 'services[-1]'        # Remove tag from services array
    local failed_services=()
    
    # Check if tag looks like a service name instead of a tag
    for valid_service in "${VALID_SERVICES[@]}"; do
        if [[ "$tag" == "$valid_service" ]]; then
            # Last argument is actually a service, not a tag
            services+=("$tag")
            tag="debug0.1"  # Use default tag
            break
        fi
    done
    
    # Check timing/windowed mode restrictions
    if [[ "$TIMING_MODE" == "true" ]] || [[ "$WINDOWED_MODE" == "true" ]]; then
        # In timing/windowed mode, check if "all" is specified
        for service in "${services[@]}"; do
            if [[ "$service" == "all" ]]; then
                log_error "Timing/Windowed mode does not support 'all' services. Please specify individual services."
                return 1
            fi
        done
    fi
    
    echo "=========================================="
    if [[ "$WINDOWED_MODE" == "true" ]]; then
        echo "Deploying Windowed Sampling Hotel Reservation Services"
    elif [[ "$TIMING_MODE" == "true" ]]; then
        echo "Deploying Timing-Enabled Hotel Reservation Services"
    else
        echo "Deploying Hotel Reservation Services"
    fi
    echo "Services: ${services[*]}"
    echo "Tag: $tag"
    if [[ "$WINDOWED_MODE" == "true" ]]; then
        echo "Mode: Windowed sampling (timing + perf counters)"
    elif [[ "$TIMING_MODE" == "true" ]]; then
        echo "Mode: Basic timing (service-specific images)"
    else
        echo "Image: ${REGISTRY}/${IMAGE_NAME}:${tag}"
    fi
    echo "=========================================="
    
    # Phase 1: Build and push image(s)
    log_info "Phase 1: Building and pushing Docker image(s)"
    if [[ "$WINDOWED_MODE" == "true" ]] || [[ "$TIMING_MODE" == "true" ]]; then
        # In timing/windowed mode, build each service individually
        for service in "${services[@]}"; do
            if ! build_and_push_docker "$tag" "$service"; then
                if [[ "$WINDOWED_MODE" == "true" ]]; then
                    log_error "Failed to build/push windowed sampling image for $service"
                else
                    log_error "Failed to build/push timing image for $service"
                fi
                failed_services+=("$service")
                continue
            fi
        done
        
        if [[ ${#failed_services[@]} -gt 0 ]]; then
            log_error "Failed to build images for: ${failed_services[*]}"
            return 1
        fi
    else
        # Normal mode: build single image for all services
        if ! build_and_push_docker "$tag" ""; then
            log_error "Failed to build/push image"
            return 1
        fi
    fi
    
    # Phase 2: Update YAML files
    log_info "Phase 2: Updating deployment YAML files"
    if ! update_yaml_files "${services[@]}" "$tag"; then
        log_error "Failed to update YAML files"
        return 1
    fi
    
    # Phase 3: Apply updated deployments and check rollouts
    log_info "Phase 3: Applying deployments and checking rollouts"
    for service in "${services[@]}"; do
        echo ""
        echo "Deploying $service"
        echo "----------------------------------------"
        
        local deployment_file="kubernetes/${service}/${service}-deployment.yaml"
        
        # Handle special cases
        case $service in
            "recommendation")
                deployment_file="kubernetes/reccomend/recommendation-deployment.yaml"
                ;;
            "reservation")
                deployment_file="kubernetes/reserve/reservation-deployment.yaml"
                ;;
        esac
        
        # Apply the deployment YAML first (ensures deployment exists)
        log_info "Applying deployment for $service"
        if ! kubectl apply -f "$deployment_file"; then
            log_error "Failed to apply deployment for $service"
            failed_services+=("$service")
            continue
        fi
        
        # Force update the image using kubectl set image (more reliable than YAML apply)
        local container_name=$(get_container_name_for_deployment "$service")
        local new_image=$(grep "image:" "$deployment_file" | grep -v "#" | awk '{print $2}' | head -1)
        
        if [[ -n "$new_image" ]]; then
            log_info "Setting image directly: deployment/$service $container_name=$new_image"
            kubectl set image "deployment/$service" "$container_name=$new_image"
        fi
        
        # Check rollout
        log_info "Checking rollout status for $service"
        if ! check_rollout "$service"; then
            log_error "Rollout failed for $service"
            failed_services+=("$service")
            continue
        fi
        
        echo " $service deployed successfully"
    done
    
    echo ""
    echo "=========================================="
    echo "DEPLOYMENT SUMMARY"
    echo "=========================================="
    
    if [ ${#failed_services[@]} -eq 0 ]; then
        echo " All services deployed successfully!"
        return 0
    else
        echo " Some services failed to deploy:"
        for failed_service in "${failed_services[@]}"; do
            echo "   - $failed_service"
        done
        echo ""
        echo "Please check the logs above for details."
        return 1
    fi
}

# Main execution starts here
log_info "Starting main execution"
cd "$(dirname "$0")" || { log_error "Failed to navigate to script directory"; exit 1; }

# Parse command line arguments
services_to_deploy=()
tag="debug0.1"  # Default tag

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode-timer)
            TIMING_MODE=true
            shift
            ;;
        --mode-windowed)
            WINDOWED_MODE=true
            shift
            ;;
        --registry=*)
            REGISTRY="${1#*=}"
            shift
            ;;
        --image-prefix=*)
            IMAGE_NAME="${1#*=}"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        all)
            if [[ "$TIMING_MODE" == "true" ]]; then
                log_error "Timing mode does not support 'all' services. Please specify individual services."
                echo ""
                show_usage
                exit 1
            fi
            services_to_deploy=("${VALID_SERVICES[@]}")
            shift
            break
            ;;
        *)
            # Check if this argument is a valid service
            if validate_service "$1"; then
                services_to_deploy+=("$1")
            else
                # Check if this looks like a tag (contains dots, numbers, or common tag patterns)
                if [[ "$1" =~ ^[a-zA-Z0-9._-]+$ && ! "$1" =~ ^(review|attractions)$ ]]; then
                    tag="$1"
                else
                    log_error "Invalid service: '$1'"
                    echo ""
                    show_usage
                    exit 1
                fi
            fi
            shift
            ;;
    esac
done

# If no services specified, show usage
if [[ ${#services_to_deploy[@]} -eq 0 ]]; then
    log_error "No services specified"
    echo ""
    show_usage
    exit 1
fi

# Check timing/windowed mode restrictions
if [[ "$TIMING_MODE" == "true" ]] || [[ "$WINDOWED_MODE" == "true" ]]; then
    # In timing/windowed mode, check if "all" is specified
    for service in "${services_to_deploy[@]}"; do
        if [[ "$service" == "all" ]]; then
            log_error "Timing/Windowed mode does not support 'all' services. Please specify individual services."
            exit 1
        fi
    done
fi

log_info "Deploying services: ${services_to_deploy[*]} with tag: $tag"
if [[ "$WINDOWED_MODE" == "true" ]]; then
    log_info "Windowed sampling mode enabled - building service-specific images with perf counters"
elif [[ "$TIMING_MODE" == "true" ]]; then
    log_info "Timing mode enabled - building service-specific images"
fi

# Deploy services
deploy_multiple_services "${services_to_deploy[@]}" "$tag"
