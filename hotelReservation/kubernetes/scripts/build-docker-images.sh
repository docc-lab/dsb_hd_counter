#!/bin/bash
cd $(dirname $0)/..


EXEC="docker buildx"

USER="docclab"

TAG="latest"

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
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# ENTER THE ROOT FOLDER
cd ../
ROOT_FOLDER=$(pwd)
$EXEC create --name mybuilder --use


for i in hotelreservation #frontend geo profile rate recommendation reserve search user #uncomment to build multiple images
 #uncomment to build multiple images
do
  IMAGE=${i}
  echo Processing image ${IMAGE}
  cd $ROOT_FOLDER
  $EXEC build --no-cache -t "$USER"/"$IMAGE":"$TAG" -f Dockerfile . --platform $PLATFORM --push
  cd $ROOT_FOLDER

  echo
done


cd - >/dev/null
