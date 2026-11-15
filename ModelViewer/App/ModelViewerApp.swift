//
//  ModelViewerApp.swift
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

@main
struct ModelViewerApp: App {
    @State private var viewer = ViewerState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewer)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Models opened from the Files app, the share sheet, or other apps.
                    viewer.open(urls: [url])
                }
                #if DEBUG
                .task {
                    openLaunchArgumentModel()
                }
                #endif
        }
    }

    #if DEBUG
    /// For testing: opens the model given by the launch argument `-OpenModel <path or URL>`.
    private func openLaunchArgumentModel() {
        guard let value = UserDefaults.standard.string(forKey: "OpenModel"), !value.isEmpty else {
            return
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://"), let url = URL(string: value) {
            viewer.openRemote(url)
            return
        }
        var url = URL(fileURLWithPath: value)
        if !value.hasPrefix("/") {
            // A path relative to the app's documents.
            url = URL.documentsDirectory.appending(path: value)
        }
        viewer.open(urls: [url])
    }
    #endif
}
