#!/bin/bash

# Configuration
REGISTRY="docclabgroup"
IMAGE_NAME="hotelreservation"

# List of services that have kubernetes deployment files
VALID_SERVICES=("frontend" "geo" "profile" "rate" "recommendation" "reservation" "search" "user")

# Function to show usage
show_usage() {
    echo "Usage: $0 <service1 [service2 ...]|all> [tag]"
    echo ""
    echo "This script follows the working approach from kubernetes/scripts/:"
    echo "  • Builds a single 'hotelreservation' image (not per-service images)"
    echo "  • Updates deployment YAML files with new image"
    echo "  • Applies updated deployments to Kubernetes"
    echo ""
    echo "Arguments:"
    echo "  service    Deploy specific service(s) (${VALID_SERVICES[*]})"
    echo "  all        Deploy all valid services"
    echo "  tag        Docker image tag (default: debug0.1)"
    echo ""
    echo "Examples:"
    echo "  $0 frontend debug0.2                    # Deploy only frontend"
    echo "  $0 frontend geo profile debug0.1        # Deploy multiple specific services"
    echo "  $0 all debug0.1                         # Deploy all valid services"
    echo "  $0 all                                  # Deploy all (default tag)"
    echo ""
    echo "Valid services: ${VALID_SERVICES[*]}"
    echo "Registry: ${REGISTRY}/${IMAGE_NAME}"
    echo "Note: 'review' and 'attractions' do not have kubernetes deployment files"
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

# Function to build and push Docker image (single image for all services)
build_and_push_docker() {
    local tag=$1
    local image_full_name="${REGISTRY}/${IMAGE_NAME}:${tag}"

    log_info "Building and pushing single Docker image for all services"

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
        
        # Use docker buildx for better platform support
        if ! sudo docker buildx build --no-cache -t "${image_full_name}" \
            -f Dockerfile . --platform "${PLATFORM}" --push; then
            log_error "Docker build/push failed"
            return 1
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
    
    log_info "Updating YAML files to use image: ${image_full_name}"
    
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
            
            # Update the image line
            if sed -i 's|image: deathstarbench/hotel-reservation:latest|image: '"${image_full_name}"'|g' "$deployment_file"; then
                if sed -i 's|image: '"${REGISTRY}/${IMAGE_NAME}"':.*|image: '"${image_full_name}"'|g' "$deployment_file"; then
                    log_success "Updated $deployment_file"
                    updated_files+=("$deployment_file")
                else
                    log_error "Failed to update $deployment_file"
                    # Restore backup
                    mv "${deployment_file}.backup" "$deployment_file"
                fi
            else
                log_error "Failed to update $deployment_file"
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
    
    echo "=========================================="
    echo "Deploying Hotel Reservation Services"
    echo "Services: ${services[*]}"
    echo "Tag: $tag"
    echo "Image: ${REGISTRY}/${IMAGE_NAME}:${tag}"
    echo "=========================================="
    
    # Phase 1: Build and push single image (only once)
    log_info "Phase 1: Building and pushing Docker image"
    if ! build_and_push_docker "$tag"; then
        log_error "Failed to build/push image"
        return 1
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
        
        # Apply the deployment
        log_info "Applying deployment for $service"
        if ! kubectl apply -f "$deployment_file"; then
            log_error "Failed to apply deployment for $service"
            failed_services+=("$service")
            continue
        fi
        
        # Check rollout
        log_info "Checking rollout status for $service"
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
    deploy_multiple_services "${VALID_SERVICES[@]}" "$TAG"
    exit $?
fi

# Check if multiple services provided
if [[ $# -gt 1 ]]; then
    # Validate all provided services
    services_to_deploy=()
    tag="debug0.1"  # Default tag
    
    for arg in "$@"; do
        # Check if this argument is a valid service
        if validate_service "$arg"; then
            services_to_deploy+=("$arg")
        else
            # Check if this looks like a tag (contains dots, numbers, or common tag patterns)
            if [[ "$arg" =~ ^[a-zA-Z0-9._-]+$ && ! "$arg" =~ ^(review|attractions)$ ]]; then
                tag="$arg"
            else
                log_error "Invalid service: '$arg'"
                echo ""
                show_usage
                exit 1
            fi
        fi
    done
    
    if [[ ${#services_to_deploy[@]} -eq 0 ]]; then
        log_error "No valid services specified"
        echo ""
        show_usage
        exit 1
    fi
    
    log_info "Deploying multiple services: ${services_to_deploy[*]} with tag: $tag"
    deploy_multiple_services "${services_to_deploy[@]}" "$tag"
    exit $?
fi

# Single service deployment
if ! validate_service "$1"; then
    log_error "Service '$1' is not a valid deployable service."
    echo ""
    show_usage
    exit 1
fi

log_info "Service '$1' validated successfully"

# Deploy single service using the new approach
deploy_multiple_services "$1" "${2:-debug0.1}"
