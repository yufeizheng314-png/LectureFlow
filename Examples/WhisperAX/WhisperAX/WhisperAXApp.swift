//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import SwiftUI

@main
struct WhisperAXApp: App {
    var body: some Scene {
        WindowGroup {
            LectureFlowView()
            #if os(macOS)
                .frame(minWidth: 1000, minHeight: 700)
            #endif
        }
    }
}
