import Foundation
import UniformTypeIdentifiers

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

func provider(_ types: UTType...) -> NSItemProvider {
    let provider = NSItemProvider()
    for type in types {
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
    }
    return provider
}

func accepts(_ providers: [NSItemProvider], fromThisApp: Bool = false, inputCovered: Bool = false) -> Bool {
    ComposerDropPolicy.accepts(providers, fromThisApp: fromThisApp, inputCovered: inputCovered)
}

let pdf = provider(.pdf)
let image = provider(.png, .jpeg)
let text = provider(.utf8PlainText)
let link = provider(.url)
let folder = provider(.folder)

require(accepts([pdf]), "A file from another app is taken")
require(accepts([image, text, link]), "Several items of different kinds are taken together")
require(accepts([]), "An empty drop is FlowDown's: taken, and nothing is imported")
require(!accepts([folder]), "A folder is refused")
require(!accepts([pdf, folder]), "One folder refuses the whole drop")
require(!accepts([NSItemProvider()]), "An item with nothing to read is refused")
require(!accepts([pdf], fromThisApp: true), "A drag that started in Apelin is refused")
require(!accepts([pdf], inputCovered: true), "Nothing lands under a request that covers the input")

/// A file on disk, as a drag from another app carries one. (A folder from
/// Files comes as `public.folder`, above; macOS gives a folder on disk only a
/// dynamic type, so it cannot stand in for one here.)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let file = scratch.appendingPathComponent("notes.txt")
try Data("notes".utf8).write(to: file)
require(NSItemProvider(contentsOf: file).map { accepts([$0]) } == true, "A file on disk is taken")
try FileManager.default.removeItem(at: scratch)

print("ok: composer drops (files, several kinds, folders, items with nothing to read, drags from Apelin, a covered input)")
