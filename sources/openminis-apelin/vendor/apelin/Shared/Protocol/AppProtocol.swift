/// The XPC side of the wire between the app and apelind. The operations,
/// their request and response types and the envelope are in
/// `Packages/ApelinKit/Sources/ApelinProtocol` (`AppOperation`, `Wire`), so
/// the workers and the Mac tests share them; this is what only the two XPC
/// peers need.
enum AppProtocol {
    static let serviceName = "wiki.qaq.apelin.service"
    static let clientEntitlement = "wiki.qaq.apelin.client"
    /// Executables allowed to connect, relative to the install root. The app
    /// is the only public peer: workers reach the session host through the
    /// socketpair it made for them, never through this service.
    static let clientPaths = ["/Applications/Apelin.app/Apelin"]
}
