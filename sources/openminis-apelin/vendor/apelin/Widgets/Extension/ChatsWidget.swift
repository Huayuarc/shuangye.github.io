import SwiftUI
import WidgetKit

/// The home screen widget: small, the one conversation that most needs a
/// look; medium, the counts and the first three. The app writes the
/// snapshot and reloads the timeline when what it shows changes, so the
/// timeline is one entry that never expires on its own.
struct ChatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ChatWidgetStore.widgetKind, provider: ChatsProvider()) { entry in
            ChatsWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName(Text("Chats"))
        .description(Text("The chats that are working or waiting for your approval."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ChatsEntry: TimelineEntry {
    let date: Date
    let snapshot: ChatWidgetSnapshot
}

struct ChatsProvider: TimelineProvider {
    func placeholder(in _: Context) -> ChatsEntry {
        ChatsEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in _: Context, completion: @escaping (ChatsEntry) -> Void) {
        completion(ChatsEntry(date: Date(), snapshot: ChatWidgetStore.read()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<ChatsEntry>) -> Void) {
        completion(Timeline(entries: [ChatsEntry(date: Date(), snapshot: ChatWidgetStore.read())], policy: .never))
    }
}

struct ChatsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    let snapshot: ChatWidgetSnapshot

    var body: some View {
        let theme = WidgetTheme(colorScheme)
        Group {
            switch family {
            case .systemSmall:
                SmallChatView(chat: snapshot.chats.first, theme: theme)
            default:
                MediumChatsView(snapshot: snapshot, theme: theme)
            }
        }
        .foregroundStyle(theme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetGround(theme.ground)
    }
}

/// The mark, then at the foot the status, the title and the project. A tap
/// opens the conversation, where a waiting approval stands in for the
/// composer; with none yet, it opens the app.
private struct SmallChatView: View {
    let chat: ChatWidgetSnapshot.Chat?
    let theme: WidgetTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkView(size: 26, braces: theme.braces)
            Spacer(minLength: 6)
            if let chat {
                HStack(spacing: 6) {
                    StatusDot(color: theme.color(for: chat.status))
                    Text(chat.statusLine)
                        .font(.rounded(.footnote, .semibold))
                        .foregroundStyle(chat.status == .done ? theme.ink.opacity(0.5) : theme.color(for: chat.status))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(verbatim: chat.title)
                    .font(.rounded(.callout, .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                Text(verbatim: chat.projectName)
                    .font(.rounded(.footnote))
                    .opacity(0.5)
                    .lineLimit(1)
                    .padding(.top, 3)
            } else {
                EmptyChatsText()
            }
        }
        .accessibilityElement(children: .combine)
        .widgetURL(chat?.link)
    }
}

/// The header, then up to three conversations, each opening its own; a tap
/// anywhere else opens the app.
private struct MediumChatsView: View {
    let snapshot: ChatWidgetSnapshot
    let theme: WidgetTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChatWidgetHeader(snapshot: snapshot, theme: theme)
            Spacer(minLength: 12)
            if snapshot.chats.isEmpty {
                EmptyChatsText()
            } else {
                ChatWidgetRows(snapshot: snapshot, theme: theme, limit: 3, spacing: 9, linksRows: true)
                Spacer(minLength: 0)
            }
        }
    }
}

/// No conversation with a message yet: an untouched New Chat is not listed.
private struct EmptyChatsText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("New Chat")
                .font(.rounded(.callout, .semibold))
            Text("No messages yet. Tap to start a chat.")
                .font(.rounded(.footnote))
                .opacity(0.5)
        }
        .accessibilityElement(children: .combine)
    }
}
