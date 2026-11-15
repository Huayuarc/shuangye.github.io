import ApelinCore
import ApelinProtocol
import ImageIO
import UIKit

/// One project as the sidebar's title and the picker show it.
struct ProjectSummary: Hashable, Sendable {
    static func load() async throws -> [ProjectSummary] {
        let folder = DataFolder.app
        return try await Task.detached {
            try folder.makeLevels(to: folder.projects)
            guard let projectsPath = CanonicalPath.resolve(folder.projects.path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try FileManager.default.contentsOfDirectory(
                atPath: folder.projects.path,
            ).sorted().compactMap { name in
                guard let url = folder.project(named: name), let root = CanonicalPath.resolve(url.path),
                      root == projectsPath + "/" + name,
                      let manifest = CanonicalPath.resolve(root + "/apelin-project.json"),
                      manifest == root + "/apelin-project.json",
                      let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
                      let document = try? JSONCoding.decode(JSONValue.self, from: data),
                      document["projectID"]?.stringValue != nil
                else { return nil }
                let kind: DevelopmentExtensionKind = switch document["kind"]?.stringValue {
                case "app": .app
                case "tweak": .tweak
                case "cli": .commandLineTool
                case "preferences": .preferenceBundle
                default: .workspace
                }
                return ProjectSummary(
                    name: name,
                    kind: kind,
                    displayName: document["displayName"]?.stringValue,
                    projectID: document["projectID"]?.stringValue,
                    automaticallyNamed: document["autoName"]?.boolValue == true,
                    buildMethod: ProjectBuildMethod(manifest: document),
                    created: (try? FileManager.default.attributesOfItem(atPath: root))?[.creationDate] as? Date,
                )
            }
        }.value
    }

    let name: String
    let kind: DevelopmentExtensionKind
    var displayName: String?
    var projectID: String?
    var automaticallyNamed = false
    /// How its package is built, if it can be yet (`ProjectBuildMethod`).
    var buildMethod = ProjectBuildMethod.missingDescription
    /// When its folder was made, which the project menu counts as its
    /// first use (`ProjectMenuOrder`); nil when it could not be read.
    var created: Date?

    var displayTitle: String {
        displayName.flatMap { ProjectDisplayName.isValid($0) ? $0 : nil } ?? name
    }

    var kindName: String {
        kind.displayName
    }
}

extension DevelopmentExtensionKind {
    /// The order kinds are listed in, workspace first.
    static let displayOrder: [DevelopmentExtensionKind] = [
        .workspace, .app, .tweak, .commandLineTool, .preferenceBundle,
    ]

    /// The kind as a section header names it.
    var displayName: String {
        switch self {
        case .workspace: String(localized: "Workspace")
        case .app: String(localized: "App")
        case .tweak: String(localized: "Tweak")
        case .commandLineTool: String(localized: "Command-Line Tool")
        case .preferenceBundle: String(localized: "Preference Bundle")
        }
    }
}

/// A project's icon: its own, when the project has one, else its kind's.
enum ProjectIcon {
    /// The project's own icon, beside its description: a square PNG. Whoever
    /// can write the project changes the icon by writing this file — the
    /// agent's file tools included — and an app sets it to the app's icon.
    static let fileName = "apelin-icon.png"

    static func image(for project: ProjectSummary) -> UIImage? {
        if let folder = DataFolder.app.project(named: project.name),
           let own = thumbnail(of: folder.appendingPathComponent(fileName))
        {
            return rounded(own)
        }
        return image(for: project.kind)
    }

    /// Decoded at the most it is drawn, the picker's 36 pt at 3x, never
    /// whole: whoever writes the project writes this file, and a small PNG
    /// can hold an image too large to decode.
    private static func thumbnail(of url: URL) -> UIImage? {
        let scale: CGFloat = 3
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 36 * scale,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    /// The kind's own icon, for a project or a template of that kind.
    static func image(for kind: DevelopmentExtensionKind) -> UIImage? {
        UIImage(named: assetName(for: kind))
    }

    /// The development extension's own icon, Apelin's braces around its
    /// mark, drawn by Scripts/render-package-icons.py.
    private static func assetName(for kind: DevelopmentExtensionKind) -> String {
        switch kind {
        case .workspace: "ProjectIconTool"
        case .app: "ProjectIconApp"
        case .tweak: "ProjectIconTweak"
        case .commandLineTool: "ProjectIconTool"
        case .preferenceBundle: "ProjectIconPreferences"
        }
    }

    /// Only the built-in artwork needs optical compensation for its inset
    /// mark and pale plate. User artwork keeps the standard toolbar size.
    static func menuImage(for project: ProjectSummary) -> UIImage? {
        let image: UIImage
        let side: CGFloat
        if let folder = DataFolder.app.project(named: project.name),
           let own = thumbnail(of: folder.appendingPathComponent(fileName))
        {
            image = rounded(own)
            side = 24
        } else {
            guard let fallback = self.image(for: project.kind) else { return nil }
            image = fallback
            side = 28
        }
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            image.draw(in: bounds)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// A project's own image is square; it is shown with an app icon's
    /// corners, as the built-in ones are drawn.
    private static func rounded(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            UIBezierPath(roundedRect: bounds, cornerRadius: side * 0.2237).addClip()
            image.draw(in: bounds)
        }
    }
}
