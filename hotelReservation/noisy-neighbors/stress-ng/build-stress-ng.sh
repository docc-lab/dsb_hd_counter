#!/bin/bash

# Build and push stress-ng Docker image
# Usage: ./build-stress-ng.sh <dockerhub-username>

if [ -z "$1" ]; then
    echo "Usage: $0 <dockerhub-username>"
    echo "Example: $0 myusername"
    exit 1
fi

USERNAME="$1"
IMAGE_NAME="stress-ng"
VERSION="0.17.08"
LATEST_TAG="latest"

echo "Building stress-ng Docker image for user: $USERNAME"

# Build the image
docker build -t ${USERNAME}/${IMAGE_NAME}:${VERSION} .
docker build -t ${USERNAME}/${IMAGE_NAME}:${LATEST_TAG} .

echo "Image built successfully!"

# Test the image
echo "Testing the image..."
docker run --rm ${USERNAME}/${IMAGE_NAME}:${LATEST_TAG} --version

# Push to Docker Hub
echo "Pushing to Docker Hub..."
docker push ${USERNAME}/${IMAGE_NAME}:${VERSION}
docker push ${USERNAME}/${IMAGE_NAME}:${LATEST_TAG}

echo "Image pushed successfully!"
echo ""
echo "✅ Setup complete! Your stress-ng image is ready."
echo ""
echo "Next steps:"
echo "1. Update USERNAME in stress-ng-helpers.sh to '${USERNAME}'"
echo "2. See README.md for usage examples"
echo "3. Try: ./stress-ng-helpers.sh help"