# 3D Model Viewer for iOS

An iOS (and iPadOS) port of [ModelViewer3D](https://github.com/dbrant/ModelViewer3D) for Android: view 3D
models in STL, OBJ, PLY, 3MF, FBX, glTF (.glb and .gltf), and OpenVDB (.vdb) formats.

Drag with one finger to rotate the model, pinch to zoom, drag with two fingers to move it, and double-tap
to reset the view.

Models are shown with their colors and materials, when the file has them, as on Android:

* **STL**: ASCII and binary, with per-facet colors in binary files (VisCAM/SolidView or Materialise Magics).
* **OBJ**: materials (colors, shininess, transparency) and diffuse textures from .mtl files, and vertex colors.
* **PLY**: ASCII and binary meshes and point clouds, with vertex colors.
* **3MF**: colors of materials, triangles, and vertices, and textures. All objects in the build are shown,
  including components in other model parts of the file.
* **FBX**: binary and ASCII, with materials and diffuse textures (embedded or in separate files). Skinned
  meshes are posed by their skeletons, in the pose that's stored in the file.
* **glTF**: materials, base color textures, alpha modes, and vertex colors. Skinned meshes are shown in
  their default pose, and morph targets with their default weights. Draco and meshopt compression aren't supported.
* **VDB**: level sets are shown as their surface, and fog volumes (smoke, clouds) are ray-marched on the
  GPU, with self-shadowing light from above. Volumes with a temperature or flames grid glow like fire.

Models that use other files (such as an OBJ model's .mtl file and textures, or a .gltf file's buffers) find
them next to the model when that's accessible — e.g. in the app's own documents, or on the web — and
otherwise the other files can be selected along with the model in the file picker.

Models can be opened from the app's file picker, from the Files app or share sheet ("Open in 3D Model
Viewer"), by dragging them onto the app on iPad, or from a web address ("Open from URL…").
The current view can be shared as an image.

## Building

Open `ModelViewer.xcodeproj` in Xcode 26 or later, and run the **ModelViewer** scheme. The app requires
iOS 18 or later. Xcode's Metal toolchain is required for the shaders; if it's missing, install it with
`xcodebuild -downloadComponent MetalToolchain`.

The unit tests (Swift Testing) are in `ModelViewerTests`, and run with ⌘U.

Parsing is much slower in Debug builds (without optimization), which is noticeable for large files such as
large VDB volumes; use a Release build to judge performance.

## Project structure

* `ModelViewer/Core`: the platform-neutral model representation (`Model`, `MeshModel`, `Material`), and
  utilities for parsers (binary and text readers, Deflate decompression, transforms).
* `ModelViewer/Formats`: a parser for each format, ported from the Android app. These depend only on
  Foundation, so they can be built and run on macOS too (see `Tools/run-parser.sh`).
* `ModelViewer/Rendering`: the Metal renderer. The shaders are ports of the Android app's OpenGL ES
  shaders, with the same lighting.
* `ModelViewer/App`: the SwiftUI app.
* `Tools`: development tools:
  * `run-parser.sh` builds the core and some formats into a macOS command-line tool, for checking parsers
    on sample files quickly (with `ModelInfo.swift`, which prints a summary of a model).
  * `preload-simulator.sh` copies sample models into the app's documents on a simulator, where they're
    visible in the Files app. In Debug builds, the launch argument `-OpenModel <file name>` opens one of
    them at launch.
  * `make-icon.swift` composes the app icon from the Android icon's background and `icon-bunny.png`, which
    was rendered by the app itself (with the Debug launch arguments `-OpenModel bunny.vdb -RenderIcon icon.png
    -IconAngles "345,165"`).

## License

Copyright 2017+ Dmitry Brant

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
