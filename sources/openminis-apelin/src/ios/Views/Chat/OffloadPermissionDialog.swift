import SwiftUI

struct OffloadPermissionDialogModifier: ViewModifier {
    @ObservedObject private var manager = OffloadPermissionManager.shared
    @ObservedObject private var development = MinisDevelopmentApprovals.shared

    private enum PresentedApproval: Identifiable {
        case offload(PermissionRequest)
        case development(MinisDevelopmentApprovals.Request)

        var id: String {
            switch self {
            case .offload(let request): return "offload:" + request.id
            case .development(let request): return "development:" + request.id.uuidString
            }
        }
    }

    private var presented: Binding<PresentedApproval?> {
        let selected: PresentedApproval?
        if let request = manager.pendingRequest {
            selected = .offload(request)
        } else {
            selected = development.pending.first.map { .development($0) }
        }
        return Binding(get: { selected }, set: { value in
            guard case nil = value else { return }
            // Capture the presented ID; dismissal must not deny the next call.
            switch selected {
            case .offload(let request):
                manager.respond(to: request.id, allowed: false)
            case .development(let request):
                development.resolve(request.id, fingerprint: request.invocation.fingerprint, allowed: false)
            case nil: break
            }
        })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: presented) { approval in
                Group {
                    switch approval {
                    case .offload(let request):
                        OffloadPermissionDialogContent(request: request)
                    case .development(let request):
                        DevelopmentPermissionDialogContent(request: request)
                    }
                }
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
            }
    }
}

private struct DevelopmentPermissionDialogContent: View {
    let request: MinisDevelopmentApprovals.Request

    private func respond(_ allowed: Bool) {
        MinisDevelopmentApprovals.shared.resolve(
            request.id, fingerprint: request.invocation.fingerprint, allowed: allowed)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Development Approval").font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: request.reason)
                    Text(verbatim: request.invocation.tool).font(.headline)
                    Text(verbatim: "Session: " + request.invocation.sessionID)
                    Text(verbatim: "Project: " + request.invocation.projectID)
                    Text(verbatim: "Directory: " + request.invocation.workingDirectory)
                    Text(verbatim: request.invocation.canonicalArguments).font(.footnote.monospaced())
                    if let digest = request.invocation.descriptionDigest {
                        Text(verbatim: "Description digest: " + digest).font(.footnote.monospaced())
                    }
                    Text(verbatim: "Binding: " + request.invocation.fingerprint).font(.caption.monospaced())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Button("Allow Once") { respond(true) }.buttonStyle(.borderedProminent)
            Button("Deny") { respond(false) }.buttonStyle(.bordered)
        }
        .padding(20)
    }
}

private struct OffloadPermissionDialogContent: View {
    let request: PermissionRequest

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable content. Long argument lists previously stretched the
            // outer VStack past the sheet height and pushed the Allow / Deny
            // buttons below the bottom edge with no way to scroll to them.
            // Pinning the buttons in a separate sibling and wrapping the rest
            // in a ScrollView guarantees the action row is always visible.
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)

                        Text("Permission Request")
                            .font(.title3.bold())

                        Text("The agent wants to use **\(request.commandName)**")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Description
                    if !request.description.isEmpty {
                        Text(request.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    // Arguments
                    let args = request.parsedArguments
                    if !args.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(args.enumerated()), id: \.offset) { idx, arg in
                                HStack {
                                    Text(arg.key)
                                        .font(.footnote.bold())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Text(arg.value)
                                        .font(.footnote.monospaced())
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                if idx < args.count - 1 {
                                    Divider().padding(.leading, 108)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                }
            }

            // Buttons — pinned to the bottom of the sheet, outside the
            // ScrollView, so they stay tappable even with very long arg lists.
            VStack(spacing: 10) {
                Button {
                    OffloadPermissionManager.shared.respond(to: request.id, allowed: true)
                } label: {
                    Text("Allow in Session")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button {
                    OffloadPermissionManager.shared.respond(to: request.id, allowed: false)
                } label: {
                    Text("Deny in Session")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
    }
}

extension View {
    func offloadPermissionDialog() -> some View {
        modifier(OffloadPermissionDialogModifier())
    }
}
