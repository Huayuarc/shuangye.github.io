import SwiftUI
import WidgetKit

/// The extension deploys to the app's floor, iOS 16.0: a jailbreak install
/// registers it whatever its minimum OS says, and iGhostVT's, built for
/// 16.2, died in dyld on an older system. The home screen widget runs from
/// 16.0; the Live Activity from 16.2, with ActivityKit linked weakly
/// (`-weak_framework ActivityKit` on this target and the app).
@main
struct ApelinWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ChatsWidget()
        if #available(iOS 16.2, *) {
            ChatsActivityWidget()
        }
    }
}
