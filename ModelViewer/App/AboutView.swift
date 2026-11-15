//
//  AboutView.swift
//  ModelViewer
//
//  Copyright 2017-2026 Dmitry Brant. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private let formats: [(String, String)] = [
        ("STL", "ASCII and binary, with per-facet colors"),
        ("OBJ", "With materials and textures (.mtl)"),
        ("PLY", "Meshes and point clouds, with vertex colors"),
        ("3MF", "With colors, materials, and textures"),
        ("FBX", "Binary and ASCII, with materials and textures"),
        ("glTF", ".glb and .gltf, with materials and textures"),
        ("VDB", "OpenVDB level sets and fog volumes"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image("AboutIcon")
                            .resizable()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(radius: 4, y: 2)
                            .accessibilityHidden(true)
                        Text("3D Model Viewer")
                            .font(.title2.bold())
                        Text("Version \(version)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Text("View 3D models that you've downloaded, or open them directly from the web. Drag to rotate, pinch to zoom, and drag with two fingers to move the model. Double-tap to reset the view.")
                } footer: {
                    Text("To open a model that uses other files, such as an OBJ model's materials and textures, select those files along with the model.")
                }

                Section("Supported Formats") {
                    ForEach(formats, id: \.0) { format in
                        LabeledContent(format.0) {
                            Text(LocalizedStringKey(format.1))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section {
                    Link(destination: URL(string: "https://github.com/dbrant/ModelViewer3D")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } footer: {
                    Text("Copyright © 2017–2026 Dmitry Brant. Licensed under the Apache License, Version 2.0. Sample models from the Stanford 3D Scanning Repository.")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AboutView()
}
