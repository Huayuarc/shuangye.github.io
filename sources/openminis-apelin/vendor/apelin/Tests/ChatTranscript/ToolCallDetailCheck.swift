import ApelinCore
import Foundation

/// A call in the trace reads as its arguments by name, each string as
/// itself, then its result; what is not a JSON object shows as it came.
func checkToolCallDetail() {
    func json(_ values: [String: JSONValue]) -> String {
        String(decoding: (try? JSONCoding.encode(JSONValue.object(values))) ?? Data(), as: UTF8.self)
    }

    let source = "#include <stdio.h>\nint main(void) {\n    printf(\"Line 175\\n\");\n}\n"
    let arguments = json([
        "reason": .string("Write the program"),
        "path": .string("Sources/main.c"),
        "content": .string(source),
    ])
    precondition(!arguments.contains("\n"), "the relay's arguments are one line, as the trace receives them")
    let written = ToolCallDetail(
        detail: arguments + "\n\n" + "Created Sources/main.c (68 bytes, +4 -0)",
        title: "Write Sources/main.c",
    )
    precondition(written.sections.map(\.name) == ["reason", "path", "content", String(localized: "Result")],
                 "the reason, the short values, the long ones, then the result: \(written.sections.map(\.name))")
    precondition(written.sections[2].value == source, "a file's content reads as the file: its line breaks and quotes")
    precondition(written.sections[3].value == "Created Sources/main.c (68 bytes, +4 -0)")
    precondition(written.text == "reason\nWrite the program\n\npath\nSources/main.c\n\ncontent\n" + source
        + "\n\n" + String(localized: "Result") + "\nCreated Sources/main.c (68 bytes, +4 -0)")

    let titled = ToolCallDetail(detail: json(["reason": .string("Build it"), "configuration": .string("debug")]), title: "Build it")
    precondition(titled.sections.map(\.name) == ["configuration"], "a reason that repeats the title is left out")
    precondition(ToolCallDetail(detail: arguments, title: "Write").sections.count == 3, "no result yet, no result section")

    let values = ToolCallDetail(detail: json([
        "lines": .array([.number(1), .number(20)]),
        "recursive": .bool(true),
        "limit": .number(5),
        "filter": .object(["kind": .string("file")]),
        "missing": .null,
    ]), title: "List files")
    precondition(values.sections.map(\.value) == ["{\"kind\":\"file\"}", "5", "[1,20]", "null", "true"],
                 "anything but a string as compact JSON: \(values.sections.map(\.value))")

    let notObject = "[\"make\",\"-j2\"]\n\nBuilt"
    precondition(ToolCallDetail(detail: notObject, title: "Run").sections == [.init(name: nil, value: notObject)])
    let garbled = "{\"path\": \"Sour\n\nUnable to read the arguments"
    precondition(ToolCallDetail(detail: garbled, title: "Read").text == garbled, "unreadable arguments show as they came")
    precondition(ToolCallDetail(detail: "\n\nDone", title: "Respring").sections == [.init(name: String(localized: "Result"), value: "Done")],
                 "a call without arguments shows its result")
    precondition(ToolCallDetail(detail: "", title: "Respring").sections.isEmpty)
    precondition(ToolCallDetail(detail: "{}\n\n", title: "Respring").sections.isEmpty, "an empty result adds nothing")
    print("ok: a call in the trace reads as its arguments by name and its result, strings as themselves")
}
