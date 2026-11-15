import Foundation
import Darwin
import MinisNativeDevelopment

guard CommandLine.arguments == [CommandLine.arguments[0], "--inherited-socket-stdin-v1"] else {
    fputs("Requires a private inherited socket from NativeConnection.launch.\n", stderr)
    exit(64)
}
do { try NativeService.run(inheritedDescriptor: STDIN_FILENO) }
catch { exit(1) }
