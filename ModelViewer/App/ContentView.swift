//
//  ContentView.swift
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
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ViewerState.self) private var viewer
    @State private var isImporting = false
    @State private var isEnteringURL = false
    @State private var urlText = ""
    @State private var isShowingAbout = false
    @State private var snapshot: Snapshot?

    var body: some View {
        @Bindable var viewer = viewer
        NavigationStack {
            ZStack {
                ModelSceneView(model: viewer.model, resetToken: viewer.resetToken, controller: viewer.scene)
                    .ignoresSafeArea()

                if viewer.model == nil && !viewer.isLoading {
                    emptyState
                }
            }
            .overlay(alignment: .bottom) {
                bottomOverlay
            }
            .navigationTitle(viewer.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    viewer.open(urls: urls)
                case .failure(let error):
                    viewer.errorMessage = error.localizedDescription
                }
            }
            .alert("Open from URL", isPresented: $isEnteringURL) {
                TextField("https://example.com/model.stl", text: $urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Open") { openEnteredURL() }
            } message: {
                Text("Enter the web address of a model. Files that it uses, such as textures, are found next to it.")
            }
            .alert("Unable to Open Model", isPresented: isPresenting($viewer.errorMessage)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewer.errorMessage ?? "")
            }
            .alert("Some Files Are Missing", isPresented: isPresenting($viewer.missingFiles)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The model was loaded, but it uses these files, which weren't found:\n\n\(viewer.missingFiles.joined(separator: "\n"))\n\nTo include them, open the model again, and select these files along with it.")
            }
            .sheet(isPresented: $isShowingAbout) {
                AboutView()
            }
            .sheet(item: $snapshot) { snapshot in
                ActivityView(items: [snapshot.image])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewer.open(urls: urls)
            return !urls.isEmpty
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Open Model", systemImage: "folder") {
                isImporting = true
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu("More", systemImage: "ellipsis") {
                Button("Open Model…", systemImage: "folder") {
                    isImporting = true
                }
                Button("Open from URL…", systemImage: "link") {
                    urlText = ""
                    isEnteringURL = true
                }
                Button("Load Sample Model", systemImage: "hare") {
                    viewer.loadNextSample()
                }
                Divider()
                Button("Reset View", systemImage: "arrow.counterclockwise") {
                    viewer.resetView()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewer.model == nil)
                Button("Share Snapshot…", systemImage: "square.and.arrow.up") {
                    if let image = viewer.scene.snapshot() {
                        snapshot = Snapshot(image: image)
                    }
                }
                .disabled(viewer.model == nil)
                Divider()
                Button("About", systemImage: "info.circle") {
                    isShowingAbout = true
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Model Open", systemImage: "cube.transparent")
        } description: {
            Text("Open an STL, OBJ, PLY, 3MF, FBX, glTF, or OpenVDB file to view it in 3D.")
        } actions: {
            Button("Open Model…") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
            Button("Load Sample Model") {
                viewer.loadNextSample()
            }
        }
        .foregroundStyle(.white, .white.opacity(0.7))
    }

    @ViewBuilder
    private var bottomOverlay: some View {
        if viewer.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading…")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
            .transition(.opacity)
        } else if let model = viewer.model {
            Text(model.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 16)
                .allowsHitTesting(false)
                .accessibilityLabel(model.summary)
        }
    }

    private func openEnteredURL() {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https", url.host() != nil else {
            viewer.errorMessage = String(localized: "That doesn't look like a valid web address.")
            return
        }
        viewer.openRemote(url)
    }

    /// A binding that's true while the value is present (non-nil, or non-empty), and clears it when set to false.
    private func isPresenting(_ value: Binding<String?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private func isPresenting(_ value: Binding<[String]>) -> Binding<Bool> {
        Binding(get: { !value.wrappedValue.isEmpty }, set: { if !$0 { value.wrappedValue = [] } })
    }
}

/// An image of the view, to share.
private struct Snapshot: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The system's share sheet.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension Model {
    /// A brief description of the model, such as how many vertices it has.
    var summary: String {
        var items: [String] = []
        if let mesh = self as? MeshModel {
            let count = mesh.isPointCloud ? mesh.vertexCount : mesh.elementCount / 3
            let noun = mesh.isPointCloud ? String(localized: "points") : String(localized: "triangles")
            items.append("\(count.formatted()) \(noun)")
            let materials = Set(mesh.parts.map(\.material)).count
            if materials > 0 {
                items.append(materials == 1 ? String(localized: "1 material") : String(localized: "\(materials) materials"))
            } else if mesh.colors != nil {
                items.append(String(localized: "vertex colors"))
            }
        } else if let volume = self as? VdbVolumeModel {
            let v = volume.volume
            items.append(String(localized: "volume \(v.sizeX)×\(v.sizeY)×\(v.sizeZ)"))
        }
        if let subtitle {
            items.append(subtitle)
        }
        return items.joined(separator: " · ")
    }
}

#Preview {
    ContentView()
        .environment(ViewerState())
}
