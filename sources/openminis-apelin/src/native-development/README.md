# Independent native development transport — minimal service

This directory is a standalone Swift 5.9 package using Foundation, CryptoKit and
Darwin. It does not use an installed Apelin/Irisin endpoint, daemon identity,
package ID, named socket, network port, shell, or elevated credentials. Source
implementation is present; macOS compilation/runtime tests have **not run on the
current iOS development device**, which has neither swift nor swiftc.

## Files and CI invocation

- `Package.swift`: library `MinisNativeDevelopment` and executable
  `native-development-service` (macOS 13+).
- `Sources/NativeDevelopment/Protocol.swift`: wire types and HMAC decision signer.
- `Sources/NativeDevelopment/Transport.swift`: bounded socket framing and
  authenticated directional sequence numbers.
- `Sources/NativeDevelopment/Service.swift`: registration, validation, ledger,
  dispatch, fixed marker side effect.
- `Sources/NativeDevelopment/Host.swift`: trusted launcher and blocking RPC API.
- `Sources/NativeDevelopmentService/main.swift`: standalone inherited-fd entry.
- `Tests/NativeDevelopmentTests/NativeDevelopmentTests.swift`: real executable
  integration tests plus malformed-packet tests.

From the repository root on a macOS runner with Swift 5.9+:

```sh
sh src/native-development/Scripts/test-macos.sh
```

The script builds the executable first, finds its actual SwiftPM bin path and
sets `NATIVE_SERVICE_EXECUTABLE` for `swift test`. Tests fail rather than skip if
this variable is missing. No repository workflow is changed here. CI should run
this command independently of the OpenMinis app build. Do not treat the shell
syntax check on this phone as a Swift compilation result.

Tests cover read, actual marker creation, deny, challenge/session cancellation,
client invalidation after disconnect, new-connection isolation, expired and repeated decisions,
wrong-key decisions, concurrent redemption, cancel/decision races, altered
session/project/tool/cwd/description/connection, unknown operations/arguments,
model risk flags, changed description, symlink description, root replacement,
and transport packet replay/MAC failure. Disconnect tests do not observe child
process termination or service-side ledger cleanup; those lifecycle properties
still require a bounded process-exit observation in macOS CI.

## Host integration API

Import `MinisNativeDevelopment`. Prefer `Call(..., operation: .hostEnvironment /
.createMarker, ...)` over the string-tool initializer. `ServiceReview` aliases
`Challenge`; its `facts` exposes operation-derived requiresAsk and fixed marker
metadata from the authenticated service challenge. `connect` aliases `launch`,
and `execute` aliases `decide`, preserving the same validation and failure modes.

`NativeConnection.connect(executable:projects:sessions:challengeLifetime:)`
returns `(NativeConnection, DecisionSigner)`. Only the trusted host startup
adapter calls it. Choose the bundled executable from trusted application
configuration, not tool arguments. Resolve host-owned project records and pass
canonical absolute roots; each root must exist and have a regular, nonsymlink,
valid JSON `apelin-project.json` whose `projectID` equals its registered ID.
The service validates roots and pins their directory descriptors/device/inode.
An arbitrary project string in a tool call cannot register a project.
Registration/session membership are fixed for the connection. Switch project,
settings or context revision by disconnecting and creating a new connection;
never keep outstanding decisions across a context switch.

Construct `Call(session:project:tool:cwd:descriptionDigest:)` with the registered
session/project, canonical root as cwd, and SHA256 hex of the **raw bytes** of
`apelin-project.json`. A host digest is only an expected value: the service
reads and hashes the real file for every prepare and decision. Only these exact
tools are supported:

| Tool | Result | Approval |
| --- | --- | --- |
| `hostEnvironment` | OS version and service process name | Read only, no challenge |
| `createMarker` | Exclusive creation of empty `.native-development-marker`, mode at most 0600, directly under pinned root | Fresh authenticated Allow Once every time |

`prepare(call)` returns a `ServiceReply`. For marker creation it returns an
immutable `Challenge`: session, project, canonical root, cwd, tool, exact digest,
random nonce, connection nonce, monotonic expiration and service-derived review.
Display this exact context in the OpenMinis trusted approval UI. Keep
`DecisionSigner` private to that UI adapter; never give it to a model, tool
handler, JS bridge or generic JSON endpoint. After the user's decision call
`signer.sign(challenge, decision: .allowOnce/.deny)` and send it via
`connection.decide(...)`. A local Bool alone is not a service credential.
The protocol always asks for `createMarker`, regardless of host approval mode;
there is no grant cache and no model-supplied risk classification.

Call `cancel(challenge)` when its sheet/task is cancelled. Call
`cancelSession(session)` to revoke the session permanently on this connection.
Both are synchronous barriers when they return. `disconnect()` interrupts
blocked I/O without waiting for the RPC lock. Run blocking calls off MainActor.
A Swift Task cancellation does not automatically invoke these blocking APIs:
the host must wire its cancellation handler to `disconnect()` (conservative,
revokes all connection work), or explicitly cancel an outstanding challenge
before deciding. Do not expose a bare async wrapper without that handler.

## Authentication and execution semantics

The launcher creates a private AF_UNIX socketpair with close-on-exec descriptors.
Foundation Process duplicates the child endpoint as stdin. The host immediately
sends fresh independent 256-bit connection, transport and decision keys in the
private inherited channel, not arguments/environment/files. No public bootstrap
listener or unauthenticated runtime registration API exists. Startup config is
trusted because the host exclusively launches the selected child and owns the
other endpoint. This is capability inheritance, not code-signature attestation:
a malicious host, substituted executable, root debugger or leaked signer is
outside this boundary and can authorize operations. A production host must
protect its bundled executable and signer accordingly.

Subsequent messages authenticate direction, connection nonce, strict per-direction
sequence and entire encoded payload with HMAC-SHA256. Frames are capped at 1 MiB;
I/O times out after 120 seconds. Decision HMAC has a distinct domain and covers
the entire service-generated challenge and decision. Unknown request fields
(including nested ones) and extra action arguments are rejected. No commands,
paths for effects, or environment data are accepted from a tool.

One service process handles one connection serially. Its dictionary is the
single ledger: any redemption attempt removes the nonce **before** MAC/context
checking; no second decision can spend it. Expiry uses system uptime, not wall
clock. Cancellation and disconnect remove pending authority; new connections
have independent keys. Denial, bad MAC, changed context, operation failure and
replay require a fresh challenge. The marker is opened relative to the pinned
root using O_EXCL/O_NOFOLLOW, so an existing file/symlink is never overwritten.

Cancellation/disconnect cannot undo a side effect already committed. Racing
cancel and decide are linearized in service request order. Immediately before
marker creation the service rechecks description/root and peer liveness. A peer
closing *after that check* may still have its already-authorized marker created;
no socket protocol can atomically combine peer liveness with a filesystem
syscall. Replays remain denied. No promise of rollback is made.

The root and description checks reduce substitution but do not freeze the whole
filesystem. An unrelated local writer can race a rename/change after validation;
the pinned descriptor keeps this fixed marker within the originally registered
directory. This minimal preset is not a secure arbitrary build/command executor.
A future executor must acquire an immutable input snapshot or a trusted mutation
barrier for build descriptions and input trees before extending the operations.
Do not extend this ledger to privileged shell/build/install as-is.

## iOS fail closed

The value types compile with an iOS 16 deployment target, but both
`NativeConnection.launch` and `NativeService.run` throw `unsupportedPlatform`
on iOS. There is no fallback to in-process approval or an installed daemon.
Foundation Process subprocess launch is not an available ordinary iOS app API;
no reviewed independent launcher, entitlement/signature setup, inherited-fd
handoff, peer identity validation or service lifecycle exists for this host.
A socketpair alone does not solve those requirements. The host must advertise
native backend unavailable on iOS until that route is implemented and tested.
No install, release, permanent package ID, iOS deployment or full native backend
capability is claimed by this package.
