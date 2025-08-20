#!/bin/bash

# Build and push stress-ng Docker image
# Usage: ./build-stress-ng.sh <dockerhub-username> <optionaltag>

if [ -z "$1" ]; then
    echo "Usage: $0 <dockerhub-username> [tag]"
    echo "Example: $0 myusername"
    echo "Example: $0 myusername v1.0"
    exit 1
fi

USERNAME="$1"
TAG="${2:-latest}"  # Use second parameter as tag, default to "latest"
IMAGE_NAME="stress-ng"
VERSION="0.17.08"

echo "Building stress-ng Docker image for user: $USERNAME with tag: $TAG"

# Build the image
docker build -t ${USERNAME}/${IMAGE_NAME}:${TAG} .

echo "Image built successfully!"

# Test the image
echo "Testing the image..."
docker run --rm ${USERNAME}/${IMAGE_NAME}:${TAG} --version

# Push to Docker Hub
echo "Pushing to Docker Hub..."
docker push ${USERNAME}/${IMAGE_NAME}:${VERSION}
docker push ${USERNAME}/${IMAGE_NAME}:${TAG}

echo "Image pushed successfully!"
echo ""
echo "✅ Setup complete! Your stress-ng image is ready."
echo ""
echo "Next steps:"
echo "1. Update USERNAME in stress-ng-helpers.sh to '${USERNAME}'"
echo "2. See README.md for usage examples"
echo "3. Try: ./stress-ng-helpers.sh help"