// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// From Apelin's app template. A manual entry point rather than `@main` on the
// app delegate: work that must finish before UIKit reads saved sessions runs
// here. UIKit reads Library/Saved Application State/<bundle id>.savedState
// before any scene delegate runs, and a leftover archive from an earlier
// Info.plist restores the old delegate. Background resumes do not enter
// main, so a live scene is left alone.
import UIKit

do {
    if let bundleIdentifier = Bundle.main.bundleIdentifier {
        let library = try FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let savedState = library
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
        if FileManager.default.fileExists(atPath: savedState.path) {
            try FileManager.default.removeItem(at: savedState)
        }
    }
} catch {
    NSLog("Could not clear saved scene state: %@", String(describing: error))
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
