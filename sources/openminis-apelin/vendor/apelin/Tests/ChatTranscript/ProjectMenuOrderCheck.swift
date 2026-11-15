import Foundation

/// The project menu lists the five projects the reader used last at the
/// top, newest first, the open one with them wherever it falls, and the
/// rest under More Projects (`ProjectMenuOrder`): a project's own use is
/// its newest conversation, else when its folder was made.
func checkProjectMenuOrder() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ hours: Double) -> Date {
        start.addingTimeInterval(hours * 3600)
    }
    func chat(_ project: String?, _ hours: Double) -> ChatSummary {
        ChatSummary(title: "", lastInteraction: at(hours), projectName: project)
    }

    let few = ProjectMenuOrder.split(
        ["Alarm", "Clock", "Dock"],
        created: [:],
        chats: [chat("Alarm", 1), chat("Dock", 3), chat("Alarm", 2)],
        open: nil,
    )
    precondition(few == .init(top: ["Dock", "Alarm", "Clock"], more: []), "five or fewer all at the top, newest first")

    let projects = ["Alarm", "Clock", "Dock", "Fan", "Gear", "Hook", "Ink"]
    let chats = [
        chat("Alarm", 7), chat("Clock", 6), chat("Dock", 5), chat("Fan", 4),
        chat("Gear", 3), chat("Hook", 2), chat("Alarm", -10), chat(nil, 9),
        chat("Gone", 8),
    ]
    let created = ["Ink": at(1), "Alarm": at(-20), "Hook": at(-30)]
    let many = ProjectMenuOrder.split(projects, created: created, chats: chats, open: nil)
    precondition(many.top == ["Alarm", "Clock", "Dock", "Fan", "Gear"], "the five used last at the top: \(many)")
    precondition(many.more == ["Hook", "Ink"], "the rest under More Projects, newest first: \(many)")

    let openOld = ProjectMenuOrder.split(projects, created: created, chats: chats, open: "Ink")
    precondition(openOld.top == ["Alarm", "Clock", "Dock", "Fan", "Gear", "Ink"], "the open one kept at the top: \(openOld)")
    precondition(openOld.more == ["Hook"])
    let openNew = ProjectMenuOrder.split(projects, created: created, chats: chats, open: "Clock")
    precondition(openNew == many, "an open one already at the top changes nothing")

    let made = ProjectMenuOrder.split(projects, created: ["Ink": at(10)], chats: chats, open: nil)
    precondition(made.top.first == "Ink" && made.more == ["Gear", "Hook"], "a folder made since the reader last wrote comes first: \(made)")

    let unused = ProjectMenuOrder.split(["Zip", "Bell", "Mug"], created: [:], chats: [], open: nil)
    precondition(unused.top == ["Bell", "Mug", "Zip"], "never used, by name")
    print("ok: the project menu lists the five projects used last, the open one, and the rest under More Projects")
}
