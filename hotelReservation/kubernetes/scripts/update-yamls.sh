#!/bin/bash

YAML_DIR="/local/DeathStarBench/hotelReservation"
DOCKER_HUB_USER="docclab"

# Ask if images are local or from dockerhub
read -p "Are the images stored locally? (y/n): " is_local

# Find all yaml files and update the image line
find "$YAML_DIR" -type f -name "*-deployment.yaml" -print0 | while IFS= read -r -d '' file; do
    service_name=$(basename "$file" | sed 's/-deployment\.yaml//')

    if [ "$is_local" = "y" ]; then
        # Update the image line for local images
        sed -i "s|image: .*|image: ${service_name}:latest|g" "$file"
    else
        # Update the image line for Docker Hub images
        sed -i "s|image: .*|image: ${DOCKER_HUB_USER}/${service_name}:latest|g" "$file"
    fi
    
    echo "Updated $file"
done