# Handoff: agent conversations (subagents and collaboration)

Branch `feature/agent-conversations`, based on `main` at `67b03e0`. Its one
commit holds the protocol and `AGENTS.md`; everything below is still to do.
This file is `Documents/Plan/Handoff-Conversations.md`; a copy and the
same change as a patch are on the owner's Desktop.

## What the owner asked for

> 增加几个 tool 让 agent 可以创建对话、分发对话消息 as the behavior of
> user，这个作为 subagent 的功能；然后各个对话之间允许开协作。

An agent in a project's chat can open another conversation in the same
project with a first message, send messages to the project's other
conversations as if the user typed them, read what they answered, and stop
the ones it opened. The conversations it opens show in the sidebar like any
other.

## Rules (the host enforces every one)

Written down in `Packages/ApelinKit/Sources/ApelinProtocol/Operations/Agent.swift`
(`AgentConversations`) and in `AGENTS.md` ▸ Agent sessions ▸ Conversations.

- An agent may call `agentOpen`, `agentPrompt`, `agentList`, `agentAttach`,
  and `agentAbort` / `agentClose` only for sessions it opened.
  `agentApprove` and `agentSteer` stay the app's.
- `agentOpen` from an agent: the project is always the caller's own (never a
  temporary one); the approval mode is the caller's current one (no
  escalation from Confirm to Relaxed); `sessionID`, `temporaryID` and
  `closeWhenFinished` cleared; a non-empty `prompt` is required; provider,
  model and effort as sent.
- At most `maximumOpenChildren` (6) agent-opened sessions run per project
  (`conflict` past it); a chain of openings is at most `maximumDepth` (2)
  deep, the app's sessions being depth 0.
- After an agent's `agentOpen` the host records the parent and depth in
  `AgentSessionTable.Entry`, and appends `conversationOpened`
  (`AgentConversations.openedEventKind`) to the opener's agent task:
  `{sessionID, task: {taskID, kind}, title?, prompt}`.
- `agentPrompt` from an agent: only to another session of the same project,
  never itself; the host re-encodes it with `fromSessionID` = caller and
  clears `approvalMode`, `provider`, `model`, `reasoningEffort`,
  `attachments` and `messageID`; descriptors are refused. The app's prompt
  has `fromSessionID` cleared, so it cannot be forged.
- `agentList` from an agent names only its project's sessions; every
  summary carries `parentSessionID`.
- `agentAttach` from an agent reads only tasks of agent sessions of its
  project (`host.attach` is generic by task ID today; check first).

Done already (in the branch commit): `AgentConversations`,
`AgentSessionSummary.parentSessionID`, `AgentPromptRequest.fromSessionID`.

## Work package 1 — host (`Apelind/`)

- `Apelind/Session/CallerPolicy.swift`: add `agentOpen`, `agentPrompt`,
  `agentList`, `agentAttach`, `agentAbort`, `agentClose` to the agent's set.
- `Apelind/Dispatch/AgentHandler.swift`: the rules above for
  `Caller.worker(.agent, instance: <caller session ID>)`. `forward(...)`
  refuses any caller but the app today; `open(...)` too. App behaviour
  unchanged.
- `Apelind/Session/Agent/AgentApprovals.swift` (`AgentSessionTable`): `Entry`
  gains `parentSessionID` and `depth`; `summaries` fills `parentSessionID`.
- Appending an event to another task: find how the host writes its own
  events (`resumed` in `Session/TaskResume.swift`, the registry's append).
- Tests in `Tests/SessionHost/`: CallerPolicy and each rule.

## Work package 2 — agent tools (`Packages/ApelinAgent/`)

Follow how the git tools were added (`Tools/ToolCatalog.swift`,
`Tools/ToolRunner.swift`, `Backend/AgentHostBackend.swift`,
`ApelinAgentWorker/ChannelHostBackend.swift`,
`Tests/ApelinAgentTests/GitToolTests.swift`, the mocks in
`Tests/ApelinAgentTests/Support.swift` and
`Tests/ApelinAgentLiveTests/CopilotLiveTests.swift`).

Project chats only (`isProjectOnly`), not General Chat:

| Tool | Host call | Risk under Confirm |
|---|---|---|
| `conversation_create {prompt, title?}` | `agentOpen` with this session's provider, model and effort; returns `{session_id, task_id}` without waiting | project edit, no ask |
| `conversation_send {session_id, text}` | `agentPrompt` (queues while the target runs) | project edit, no ask |
| `conversation_list {}` | `agentList`: id, title, state, parent, updated | read |
| `conversation_read {session_id, after_seq?, wait_seconds?}` | find the task with `agentList`, read with attach; state (running / waitingForApproval / idle / ended), the assistant's `message` texts in the range, pending approvals, last seq; `wait_seconds` 0–180 long-polls to the next `finished`, `waitingForApproval` or timeout; output capped (~32 KiB, marked truncated) | read |
| `conversation_stop {session_id}` | `agentAbort`, own children only | project edit, no ask |

The opened conversation runs under the same Confirm, so its own risky steps
still ask the user.

- Worker: when `AgentPromptRequest.fromSessionID` is set, the `prompt` event
  payload gains `from: <sessionID>` (EventRelay in
  `ApelinAgentWorker/AgentWorker.swift`), and the model sees one short
  prefix line saying the message came from conversation <title or id>,
  not from the user.
- `Session/SystemPrompt.swift`, a short Conversations section: delegate an
  independent subtask with conversation_create (another agent, same
  approval mode); what conversation_send says reads as the user's words, so
  state the task and the deliverable; collect with conversation_read
  (`wait_seconds`); never let two conversations edit the same files at
  once; open one only when work can truly run in parallel; a message
  `from` another conversation is a collaborating agent, not the user.
- `Apelin/Interface/Chats/ChatTranscript.swift` `toolTitle`: titles for the
  five tools (Create a conversation / Send to a conversation / List
  conversations / Read a conversation / Stop a conversation), in
  `Apelin/Resources/Localizable.xcstrings` with zh-Hans (新建对话 / 发送给对话
  / 列出对话 / 读取对话 / 停止对话), `extractionState: manual`.
- Tests: catalog (names, risks, project-only), backend request shapes
  (create carries this session's provider/model; send carries no mode),
  read's long poll and cap, the `from` on the prompt event.

## Work package 3 — app (`Apelin/`)

- `Apelin/Interface/Chats/ChatRuntime.swift`:
  - in `follow`, a `conversationOpened` event whose `sessionID` no record
    has → a new `ChatRecord` in the parent's `projectName`, titled by
    `title` or the start of `prompt`, with `sessionID` and `task`, persisted,
    then `follow`ed; the selection does not change;
  - in `load`, a live session from `agentList` with `parentSessionID` and no
    record is adopted the same way (project from the parent's record; skip
    when the parent has none), so nothing is missed when the app was not
    running.
- A `prompt` with `from`: one footnote line in secondaryLabel over the user
  bubble, "From <that conversation's title>" (else "From another
  conversation"), no icon, and spoken by VoiceOver (AGENTS.md accessibility
  rules; `make check` runs `Scripts/check-accessibility.py`).
- Where it can be pure logic (adopting on `conversationOpened`), test it the
  way the chat checks in `make harness` are hooked in.

## Verify and finish (AGENTS.md ▸ Build & verify)

1. `make check`, `make harness` (host tests, every package, apelind and
   workers typechecked). `make format` only on the files you touched.
2. `AGENTS.md`'s Conversations paragraph is already written; correct it if
   the implementation differs.
3. On a device (local only, not in the cloud): `make vphone VPHONE=Banana`
   (the iPad; the iPhone vphone is off), then `make device-test
   SUITE=smoke VPHONE=Banana`; in a project chat ask the agent to open a
   conversation and send it a task; check it appears in the sidebar, runs,
   shows "From …" on the bubble, and that the parent reads its answer.
4. Before pushing: read the diff and the built binaries' `strings` for
   credentials, home or scratch paths, hostnames and device identifiers.
5. Commit, push, and report each step that ran and each that did not.

## Repository notes

- History was squashed to one root commit on 2026-10-22; the old branches
  are only in a local bundle on the owner's Mac.
- The owner reads replies in Chinese; code, commits and docs stay English.
