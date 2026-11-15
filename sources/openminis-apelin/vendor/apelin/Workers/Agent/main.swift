import ApelinAgentWorker

// apelin-agent: one agent session (KWWKAgent) per process, or — as the
// `credential-import` instance — the console's credential inbox and the
// provider sign-ins Settings ▸ Model Providers starts.
//
// Runs as mobile, spawned by apelind's session host with its socketpair as
// descriptor 3; WorkerMain does the assignment and the privilege check.
// Links ApelinCore, ApelinProtocol, ApelinProject and Packages/ApelinAgent's
// ApelinAgentWorker — see AGENTS.md ▸ Decisions ▸ Process layout. The logic
// lives in ApelinAgentWorker so `make harness` tests it on the Mac.

AgentWorker.main()
