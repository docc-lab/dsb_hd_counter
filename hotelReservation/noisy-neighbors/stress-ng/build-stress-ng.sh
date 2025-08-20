#!/bin/bash

# Build and push stress-ng Docker image
# Usage: ./build-stress-ng.sh [your-dockerhub-username]

USERNAME=${1:-"yourusername"}
IMAGE_NAME="stress-ng"
VERSION="0.17.08"
LATEST_TAG="latest"

echo "Building stress-ng Docker image..."

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

echo "Stress-ng Examples for Kubernetes"
echo "================================="
echo ""
echo "1. CPU Stress:"
echo "kubectl run cpu-stress --image=$IMAGE --restart=Never -- --cpu 4 --timeout 60s"
echo ""
echo "2. Memory Pressure:"
echo "kubectl run mem-pressure --image=$IMAGE --restart=Never -- --brk 2 --timeout 60s"
echo ""
echo "3. VM (Virtual Memory) Stress:"
echo "kubectl run vm-stress --image=$IMAGE --restart=Never -- --vm 2 --vm-bytes 512M --timeout 60s"
echo ""
echo "4. Page Fault Stress:"
echo "kubectl run page-fault --image=$IMAGE --restart=Never -- --fault 1 --timeout 60s"
echo ""
echo "5. I/O Stress:"
echo "kubectl run io-stress --image=$IMAGE --restart=Never -- --io 2 --timeout 60s"
echo ""
echo "6. Network/Socket Stress:"
echo "kubectl run sock-stress --image=$IMAGE --restart=Never -- --sock 2 --timeout 60s"
echo ""
echo "7. Combined Noisy Neighbor:"
echo "kubectl run noisy-neighbor --image=$IMAGE --restart=Never -- --cpu 2 --vm 1 --vm-bytes 1G --brk 1 --io 2 --sock 1 --timeout 0"
echo ""
echo "8. Heavy Load (use all CPUs):"
echo "kubectl run heavy-load --image=$IMAGE --restart=Never -- --cpu 0 --vm 2 --vm-bytes 2G --io 4 --timeout 300s"
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