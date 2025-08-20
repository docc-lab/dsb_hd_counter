#!/bin/bash

# Build and push stress-ng Docker image
# Usage: ./build-stress-ng.sh [your-dockerhub-username]

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
echo "Quick usage examples:"
echo "kubectl run cpu-stress --image=${USERNAME}/${IMAGE_NAME}:${LATEST_TAG} --restart=Never -- --cpu 4 --timeout 60s"
echo "kubectl run vm-stress --image=${USERNAME}/${IMAGE_NAME}:${LATEST_TAG} --restart=Never -- --vm 2 --vm-bytes 512M --timeout 60s"
echo "kubectl run noisy-neighbor --image=${USERNAME}/${IMAGE_NAME}:${LATEST_TAG} --restart=Never -- --cpu 2 --vm 1 --vm-bytes 1G --io 2 --timeout 0"
echo ""
echo "For more examples, see the generated stress-ng-examples.sh file"

# Create separate examples file
echo "Creating stress-ng-examples.sh..."
cat > stress-ng-examples.sh << 'EOF'
#!/bin/bash
# Stress-ng Kubernetes Examples
# Simple one-liners using stress-ng Docker image

# Change this to your Docker Hub username
USERNAME="yourusername"
IMAGE="${USERNAME}/stress-ng:latest"

echo "Stress-ng Examplry Usage for Kubernetes"
echo "source stress-ng-helpers.sh first!"
echo "================================="
echo ""
echo "1. CPU Stress:"
echo "cpu [workers] [duration]"
echo "Equvilent to: kubectl run cpu-stress --image=$IMAGE --restart=Never -- --cpu 4 --timeout 60s"
echo ""
echo "2. Memory Pressure:"
echo "memory [workers] [duration]"
echo "Equvilent to: kubectl run mem-pressure --image=$IMAGE --restart=Never -- --brk 2 --timeout 60s"
echo ""
echo "3. VM (Virtual Memory) Stress:"
echo "vm [workers] [size] [duration]"
echo "Equvilent to: kubectl run vm-stress --image=$IMAGE --restart=Never -- --vm 2 --vm-bytes 512M --timeout 60s"
echo ""
echo "4. Page Fault Stress:"
echo "page-fault [workers] [duration]"
echo "Equvilent to: kubectl run page-fault --image=$IMAGE --restart=Never -- --fault 1 --timeout 60s"
echo ""
echo "5. I/O Stress:"
echo "io [workers] [duration]"
echo "Equvilent to: kubectl run io-stress --image=$IMAGE --restart=Never -- --io 2 --timeout 60s"
echo ""
echo "6. Network/Socket Stress:"
echo "network [workers] [duration]"
echo "Equvilent to: kubectl run sock-stress --image=$IMAGE --restart=Never -- --sock 2 --timeout 60s"
echo ""
echo "7. Combined Noisy Neighbor:"
echo "noisy [duration]"
echo "Equvilent to: kubectl run noisy-neighbor --image=$IMAGE --restart=Never -- --cpu 2 --vm 1 --vm-bytes 1G --brk 1 --io 2 --sock 1 --timeout 0"
echo ""
echo "Cleanup:"
echo "kubectl delete pod cpu-stress mem-pressure vm-stress page-fault io-stress sock-stress noisy-neighbor heavy-load"
echo ""
echo "Quick Tips:"
echo "- Use --timeout 0 for infinite duration (until pod is deleted)"
echo "- Use --cpu 0 to use all available CPUs"
echo "- Memory sizes: 256M, 512M, 1G, 2G etc."
echo "- Add --limits='cpu=2,memory=1Gi' to kubectl run for resource limits"
EOF

chmod +x stress-ng-examples.sh

echo "Created stress-ng-examples.sh - run it to see usage examples!"
echo "Usage: ./stress-ng-examples.sh"