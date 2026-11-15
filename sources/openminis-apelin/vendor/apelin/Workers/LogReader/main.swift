import ApelinLogReaderWorker

// apelin-log-reader: system log reading that needs root, over a filter the
// host has checked. System libraries only: never a third-party library,
// never icli.
//
// Runs as root, spawned by apelind's session host — only when
// apelin-diagnostics cannot read the live log as mobile — with its
// socketpair as descriptor 3; WorkerMain does the assignment.
// Links ApelinCore, ApelinProtocol and Packages/ApelinDiagnostics'
// ApelinLogReaderWorker (ApelinLogReader: Foundation, libobjc, LoggingSupport
// opened at run time) and nothing else, ever — `make harness` checks it.

LogReaderWorker.main()
