//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import SwiftUI

@main
@MainActor
struct WhisperAXApp: App {
    @StateObject private var lectureModel = LectureFlowModel()
    var body: some Scene {
        WindowGroup {
            LectureFlowView(model: lectureModel)
            #if os(macOS)
                .frame(minWidth: 1000, minHeight: 700)
            #endif
        }
    }
}
