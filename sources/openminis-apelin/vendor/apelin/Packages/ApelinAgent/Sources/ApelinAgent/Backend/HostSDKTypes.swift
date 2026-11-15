import Foundation

// MARK: - SDK

public struct RegisteredSDKRequest: Sendable, Hashable, Codable {
    /// nil for the project's selected SDK.
    public var sdkID: String?
    public var project: ProjectIdentity
    public init(sdkID: String?, project: ProjectIdentity) {
        self.sdkID = sdkID
        self.project = project
    }
}

public struct RegisteredSDKResponse: Sendable, Hashable, Codable {
    public var sdkID: String
    /// Physical path of the SDK root, readable by mobile.
    public var rootPath: String
    public var platform: String
    public var version: String
    public init(sdkID: String, rootPath: String, platform: String, version: String) {
        self.sdkID = sdkID
        self.rootPath = rootPath
        self.platform = platform
        self.version = version
    }
}
