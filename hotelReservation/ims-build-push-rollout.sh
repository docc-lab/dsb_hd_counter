#!/bin/bash

# Configuration
REGISTRY="docclabgroup"

# List of services that have kubernetes deployment files
VALID_SERVICES=("frontend" "geo" "profile" "rate" "recommendation" "reservation" "search" "user")

# Function to show usage
show_usage() {
    echo "Usage: $0 <service|all> [tag]"
    echo ""
    echo "Arguments:"
    echo "  service    Deploy a specific service (${VALID_SERVICES[*]})"
    echo "  all        Deploy all valid services"
    echo "  tag        Docker image tag (default: debug0.1)"
    echo ""
    echo "Examples:"
    echo "  $0 frontend debug0.2           # Deploy only frontend service"
    echo "  $0 all debug0.1                # Deploy all valid services"
    echo "  $0 all                         # Deploy all valid services with default tag"
    echo ""
    echo "Valid services: ${VALID_SERVICES[*]}"
    echo "Note: 'review' and 'attractions' do not have kubernetes deployment files"
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

# Function to build and push Docker image
build_and_push_docker() {
    local service=$1
    local tag=$2
    local base_image="hotelreservation-base:${tag}"

    log_info "Building and pushing Docker image for $service"

    # Check if base image already exists locally
    if ! sudo docker image inspect "${base_image}" >/dev/null 2>&1; then
        log_info "Building base Docker image: ${base_image}"
        if ! sudo docker build -t "${base_image}" .; then
            log_error "Docker build failed for base image"
            return 1
        fi
        log_success "Base image built successfully"
    else
        log_info "Base image ${base_image} already exists, reusing it"
    fi

    # Tag the base image for the specific service
    log_info "Tagging image for service $service:$tag"
    if ! sudo docker tag "${base_image}" "${REGISTRY}/${service}:${tag}"; then
        log_error "Docker tag failed for $service"
        return 1
    fi

    # Push Docker image
    log_info "Pushing Docker image for $service:$tag"
    if ! sudo docker push "${REGISTRY}/${service}:${tag}"; then
        log_error "Docker push failed for $service"
        return 1
    fi

    log_success "Successfully built and pushed Docker image for $service"
}

# Function to check rollout status
check_rollout() {
    local service=$1
    local failed_rollouts=()
    local success=true

    log_info "Checking rollout status for updated service"

    log_info "Checking rollout status for $service"
    if ! kubectl rollout status "deployment/${service}" --timeout=300s; then
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

# Function to deploy all valid services
deploy_all_services() {
    local tag=$1
    local failed_services=()
    
    echo "=========================================="
    echo "Deploying All Hotel Reservation Services"
    echo "Tag: $tag"
    echo "Valid services: ${VALID_SERVICES[*]}"
    echo "=========================================="
    
    for service in "${VALID_SERVICES[@]}"; do
        echo ""
        echo "Building and Deploying $service"
        echo "----------------------------------------"
        
        # Reset failed_services array for individual service
        failed_services_single=()
        
        # Build and push
        if ! build_and_push_docker "$service" "$tag"; then
            failed_services+=("$service")
            echo "❌ $service build/push failed"
            continue
        fi
        
        # Update deployment
        log_info "Phase 3: Updating Kubernetes deployment for $service"
        log_info "Setting new image for $service"
        if ! kubectl set image "deployment/$service" "hotel-reserv-$service=${REGISTRY}/$service:$tag"; then
            log_error "Failed to update image for $service"
            failed_services+=("$service")
            continue
        fi
        
        # Check rollout
        log_info "Phase 4: Checking rollout status for $service"
        if ! check_rollout "$service"; then
            log_error "Rollout failed for $service"
            failed_services+=("$service")
            continue
        fi
        
        echo "✅ $service deployed successfully"
    done
    
    echo ""
    echo "=========================================="
    echo "DEPLOYMENT SUMMARY"
    echo "=========================================="
    
    if [ ${#failed_services[@]} -eq 0 ]; then
        echo "🎉 All services deployed successfully!"
        return 0
    else
        echo "⚠️  Some services failed to deploy:"
        for failed_service in "${failed_services[@]}"; do
            echo "   - $failed_service"
        done
        echo ""
        echo "Please check the logs above for details."
        return 1
    fi
}

# Main execution starts here
log_info "Phase 1: Starting main execution"
cd "$(dirname "$0")" || { log_error "Failed to navigate to script directory"; exit 1; }

# Check for help or invalid arguments
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] || [[ -z "$1" ]]; then
    show_usage
    exit 0
fi

# Check if user wants to deploy all services
if [[ "$1" == "all" ]]; then
    TAG="${2:-debug0.1}"  # Default to debug0.1 if no tag provided
    log_info "Deploying all valid services with tag: $TAG"
    deploy_all_services "$TAG"
    exit $?
fi

# Validate single service
if ! validate_service "$1"; then
    log_error "Service '$1' is not a valid deployable service."
    echo ""
    show_usage
    exit 1
fi

log_info "Service '$1' validated successfully"

# Second Phase: Build and Push Docker Images
log_info "Phase 2: Building and pushing Docker images"
echo -e "\n----------------------------------------"
if ! build_and_push_docker "$1" "$2"; then
    failed_services+=("$1")
fi
echo "----------------------------------------"

if [ ${#failed_services[@]} -ne 0 ]; then
    log_error "Failed to build/push the following services: ${failed_services[*]}"
    exit 1
fi

# Third Phase: Update Kubernetes Deployments
log_info "Phase 3: Updating Kubernetes deployments"
echo "Updating all service images simultaneously..."

log_info "Setting new image for $1"
kubectl set image "deployment/$1" "hotel-reserv-$1=${REGISTRY}/$1:$2" &

# Wait for all kubectl set image commands to complete
log_info "Waiting for all image updates to complete"
wait
log_success "All deployment image updates initiated"

# Fourth Phase: Check Rollout Status
log_info "Phase 4: Checking rollout status for updated service"
if ! check_rollout "$1"; then
    log_error "Deployment failed to roll out properly"
    exit 1
fi
