# ApelinToolHost

The agent-tool-extension protocol (milestone 1 plan, §6): how Apelin's
session host runs a tool that ships in its own package and its own process.
Both ends live here, on system libraries only.

| Product | Who links it | What it is |
|---|---|---|
| `ApelinToolCore` | both | frames, manifest and its validation, attachment socket, schema check |
| `ApelinToolHost` | the session host | `ToolHostClient`: spawns one extension and talks to it |
| `ApelinToolExtension` | an extension executable | `ToolExtensionServer`: implements the tools |

`swift test` runs the protocol against `FakeToolExtension`, an extension that
misbehaves on request.

## Manifest

`<install root>/usr/share/apelin/agent-tools/<id>/manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "wiki.qaq.apelin.agent-tools.example",
  "name": "Example",
  "version": "1.0.0",
  "license": "MIT",
  "licenseFiles": ["licenses/LICENSE"],
  "executable": "usr/libexec/apelin/agent-tools/apelin-example",
  "protocolVersions": [1],
  "tools": [
    {
      "name": "example",
      "description": "What the agent reads.",
      "parameters": {"type": "object", "properties": {}, "additionalProperties": false},
      "risk": "readOnly",
      "timeoutSeconds": 30
    }
  ]
}
```

`ToolManifestValidator` accepts a manifest only when:

- the id is lowercase `[a-z0-9.-]`, and is the name of its directory;
- the directory, the manifest and the executable, each `realpath`ed, are
  inside the canonical install root, compared by components;
- each is owned by root (the policy's `requiredOwner`) and not writable by
  group or others; the executable is a regular file its owner can execute;
- `executable` and every `licenseFiles` entry are plain relative paths (no
  leading `/`, no `..`), the latter inside the manifest's directory;
- `protocolVersions` shares a version with the host, tool names are unique,
  every tool has a description and an object schema, and `risk` is
  `readOnly`, `writeProject` or `system`.

`discover(installRoot:)` returns one result per directory, so a bad manifest
is isolated to its own entry. `ToolHostClient(validated:)` checks the
executable again right before spawning it. The declared `risk` is the
extension's claim; the host classifies each tool from it *and* what the
extension can actually do.

## Wire

One JSON object per line. The host writes to the extension's stdin; the
extension writes to its stdout. stderr is the extension's log, never parsed:
each line goes to `logHandler`, and the last lines are kept for crash
reports. Every frame carries `protocolVersion` and `requestID` (1–128
printable ASCII bytes).

| Frame | Direction | Fields |
|---|---|---|
| `hello` | host → ext | `supportedVersions`, `peer {name, version}`, `maxConcurrentCalls`, `maxFrameBytes` |
| `hello` | ext → host | the chosen `protocolVersion`, `supportedVersions`, `peer` (name = extension id), `tools`, `maxConcurrentCalls`, `maxFrameBytes` |
| `call` | host → ext | `tool`, `args`, optional `attachments [{id, argument, mimeType, name, byteCount}]` |
| `cancel` | host → ext | the call's `requestID` |
| `result` | ext → host | `content [{type: "text", text} \| {type: "attachment", id, mimeType, name, byteCount}]` |
| `error` | ext → host | `error {code, message}` |

```
→ {"protocolVersion":1,"type":"hello","requestID":"hello","supportedVersions":[1],"peer":{"name":"apelin","version":"1.0"},"maxConcurrentCalls":4,"maxFrameBytes":1048576}
← {"protocolVersion":1,"type":"hello","requestID":"hello","peer":{"name":"wiki.qaq.apelin.agent-tools.example","version":"1.0.0"},"tools":["example"],"maxConcurrentCalls":4,"maxFrameBytes":1048576,"supportedVersions":[1]}
→ {"protocolVersion":1,"type":"call","requestID":"c1","tool":"example","args":{}}
← {"protocolVersion":1,"type":"result","requestID":"c1","content":[{"type":"text","text":"done"}]}
```

Every call ends with exactly one `result` or `error`. Error codes:
`protocolVersionMismatch`, `badFrame`, `frameTooLarge`, `notNegotiated`,
`unknownTool`, `invalidArguments`, `busy`, `duplicateRequest`, `toolFailed`,
`resultTooLarge`, `attachmentRejected`, `cancelled`, `timeout`,
`extensionCrashed`, `extensionTerminated`, `extensionNotRunning`; a code this
build does not know reads as `unknown`.

### Versions

The host offers `supportedVersions`; the extension picks the highest it
shares, or answers `error protocolVersionMismatch` and the host's `start()`
throws. Every later frame must carry the negotiated version; one that does
not stops the extension.

### Limits (`ToolProtocolLimits`, host defaults)

| | |
|---|---|
| frame | 1 MiB per line; longer stops the extension (host side) or is answered `frameTooLarge` and skipped (extension side); a result that would be longer is answered `resultTooLarge` |
| concurrency | 4 in flight, lowered by the extension's `hello`; the host queues the rest, the extension answers `busy` past its own |
| hello | 5 s |
| call timeout | 30 s default, the manifest's `timeoutSeconds` if set, capped at 300 s |
| cancel grace | 2 s; a cancelled or timed-out call keeps its slot until the extension ends it, and past the grace the host stops the process |
| attachments | 8 per frame, 32 MiB each, regular files only, 32 unclaimed at a time, 2 s for one to arrive |

### Failure

A call never throws. It returns `.failure` with a code: an unparseable
frame, an oversized frame, a wrong version or a frame type an extension may
not send stops the process and fails every call in flight with that reason;
a process that exits fails them with `extensionCrashed`, its exit status and
its last log lines. One extension ending does not end the agent session: the
host makes a new client.

### Attachments

Files never travel as base64. The host passes an `AF_UNIX` datagram socket
as descriptor 3 (named in `APELIN_TOOL_ATTACHMENT_FD`). The sender sends
each file over it first — the attachment ID as the payload, exactly one
descriptor as `SCM_RIGHTS` — and then the frame naming that ID. The receiver
maps the ID to the descriptor the kernel installed in *its own* table; a
descriptor number never appears in JSON. Received descriptors are checked on
arrival (a regular file under the limit), held until claimed, and closed if
nobody claims them. A `call` attachment with `argument` stands in for that
argument: the host can open a file and hand over the descriptor rather than
the path. Passing a descriptor is not a sandbox, and nothing here makes it
safe to run a hostile extension.

### Process

`ToolHostClient` spawns with `posix_spawn` and `POSIX_SPAWN_CLOEXEC_DEFAULT`
— the child gets stdin, stdout, stderr and descriptor 3, nothing else the
host has open — default signal dispositions, an empty mask, its own process
group, and only the environment it is given. It refuses to spawn as root
unless told to: extensions run as mobile.

`ToolExtensionServer.run()` reserves stdout for frames by moving it to a
private descriptor and pointing descriptor 1 at stderr, so a stray `print`
lands in the log. When stdin ends, calls in flight get `cancelGrace` to
finish, are then cancelled, and the process exits; `terminate()` closes stdin
and kills the process a second after that window if it is still there. Run
with `--describe`, an extension prints its descriptors
as JSON, which lets a test hold the shipped manifest to the code.

## Writing an extension

```swift
import ApelinToolExtension

let server = ToolExtensionServer(
    peer: ToolPeer(name: "wiki.qaq.apelin.agent-tools.example", version: "1.0.0"),
    tools: [
        ToolHandler(ToolDescriptor(name: "example", description: "…",
                                   parameters: ["type": "object"], risk: .readOnly)) { call in
            try call.checkCancellation()
            return .text("done")
        },
    ]
)
server.run()
```
