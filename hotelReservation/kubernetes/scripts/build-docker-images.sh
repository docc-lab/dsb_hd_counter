#!/bin/bash
cd $(dirname $0)/..


EXEC="docker buildx"

USER="docclab"

TAG="latest"

# ENTER THE ROOT FOLDER
cd ../
ROOT_FOLDER=$(pwd)
$EXEC create --name mybuilder --use

for i in hotel_reserv_frontend_single_node hotel_reserv_search_single_node hotel_reserv_rate_single_node hotel_reserv_user_single_node hotel_reserv_profile_single_node hotel_reserv_recommendation_single_node hotel_reserv_geo_single_node hotel_reserv_reserve_single_node
 #uncomment to build multiple images
do
  IMAGE=${i}
  echo Processing image ${IMAGE}
  cd $ROOT_FOLDER
  $EXEC build --no-cache -t "$USER"/"$IMAGE":"$TAG" -f Dockerfile . --platform linux/arm64 --push
  cd $ROOT_FOLDER

  echo
done


cd - >/dev/null
