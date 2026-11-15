// snapshot <page.html> <out.png> <width> <height> <scale>
//
// Renders a local page at width × height points into a PNG `scale` times as
// large, with WebKit: render.mjs's page of Banner.fig.
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count == 6, let width = Double(arguments[3]), let height = Double(arguments[4]),
      let scale = Double(arguments[5])
else {
    FileHandle.standardError.write(Data("usage: snapshot <page.html> <out.png> <width> <height> <scale>\n".utf8))
    exit(2)
}

let page = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: width, height: height),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false,
)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
window.contentView = webView

final class Snapshotter: NSObject, WKNavigationDelegate {
    private let pixelWidth: Double
    private let output: URL

    init(pixelWidth: Double, output: URL) {
        self.pixelWidth = pixelWidth
        self.output = output
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        // Every image is a CSS background, decoded after the load finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: self.pixelWidth)
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:])
                else {
                    FileHandle.standardError.write(Data("snapshot failed: \(String(describing: error))\n".utf8))
                    exit(1)
                }
                do {
                    try png.write(to: self.output)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }
}

let snapshotter = Snapshotter(pixelWidth: width * scale, output: output)
webView.navigationDelegate = snapshotter
webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
NSApplication.shared.run()
