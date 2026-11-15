import CAppXPC
import XPC

/// The XPC constants, read through C rather than through Swift's XPC overlay.
///
/// Naming the SDK's XPC type, array-append or connection-error macros in Swift
/// links `/usr/lib/swift/libswiftXPC.dylib` as a required library, and iOS 15
/// does not have it: dyld terminates the process before `main` with "Library
/// not loaded". Through the C shim they are the libSystem globals they have
/// always been, the overlay stays weakly linked and unused, and the same binary
/// runs on iOS 15 and on iOS 26 — one path on every OS, so the version you test
/// on is the version that runs everywhere.
///
/// Put this file in whatever group every target already compiles (the app and
/// the daemon), and let `make check` fail on any Swift file that spells the
/// macros directly.
enum AppXPC {
    static var typeArray: xpc_type_t {
        app_xpc_type_array()
    }

    static var typeBool: xpc_type_t {
        app_xpc_type_bool()
    }

    static var typeConnection: xpc_type_t {
        app_xpc_type_connection()
    }

    static var typeDictionary: xpc_type_t {
        app_xpc_type_dictionary()
    }

    static var typeError: xpc_type_t {
        app_xpc_type_error()
    }

    static var typeFD: xpc_type_t {
        app_xpc_type_fd()
    }
}
