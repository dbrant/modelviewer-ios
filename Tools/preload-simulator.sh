#!/bin/zsh
# Copies sample models into the app's Documents folder on a booted simulator, where they appear in
# the Files app under On My iPhone › 3D Model Viewer (and can be opened with -OpenModel <name>).
#
# Usage: Tools/preload-simulator.sh [directory of models] [simulator (default: booted)]
set -e
SOURCE=${1:-~/Downloads/3d}
SIM=${2:-booted}
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.dmitrybrant.modelviewer data)
mkdir -p "$CONTAINER/Documents"
for f in "$SOURCE"/*.(stl|STL|obj|mtl|ply|vdb|3mf|fbx|glb|gltf|bin|png|jpg|jpeg)(N); do
  cp "$f" "$CONTAINER/Documents/"
done
ls "$CONTAINER/Documents"
