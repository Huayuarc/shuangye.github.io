@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// apelin_sdk_analyze_framework and apelin_sdk_read_header against a small SDK
/// tree: both framework folders, a header named after a class it does not
/// hold, and a header that links out of the SDK.
@Suite("SDK framework tools")
struct FrameworkToolTests {
    let base: URL
    let sdkURL: URL
    let tools: FrameworkTools

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apelin-framework-tests-\(UUID().uuidString)", isDirectory: true)
        let sdkURL = base.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        self.sdkURL = sdkURL
        func write(_ relative: String, _ content: String) throws {
            let url = sdkURL.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        try write("System/Library/Frameworks/Vision.framework/Vision.tbd", Self.visionStub)
        try write("System/Library/Frameworks/Vision.framework/Headers/VNObservation.h", Self.observationHeader)
        try write("System/Library/Frameworks/Vision.framework/Headers/VNRequest.h", Self.requestHeader)
        try write("System/Library/Frameworks/UIKit.framework/UIKit.tbd", Self.stub(for: "Frameworks/UIKit"))
        try write(
            "System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome.tbd",
            Self.stub(for: "PrivateFrameworks/SpringBoardHome"),
        )
        try FileManager.default.createDirectory(
            at: sdkURL.appendingPathComponent("System/Library/PrivateFrameworks/SpringBoardFoundation.framework"),
            withIntermediateDirectories: true,
        )

        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "@interface VNSecretObservation : VNObservation\n@end\n"
            .write(to: outside.appendingPathComponent("Secret.h"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: sdkURL.appendingPathComponent("System/Library/Frameworks/Vision.framework/Headers/VNSecret.h").path,
            withDestinationPath: outside.appendingPathComponent("Secret.h").path,
        )

        tools = try FrameworkTools(sdk: ScopedRoot(sdkURL))
    }

    private func message(_ body: () throws -> String) -> String? {
        do { _ = try body(); return nil } catch { return error.localizedDescription }
    }

    // MARK: - Both folders

    @Test
    func `a private framework is found without private`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let output = try tools.analyze(["framework": "SpringBoardHome"])
        #expect(output.hasPrefix("SpringBoardHome.framework (PrivateFrameworks)\n"))
        #expect(output.contains("install name: /System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome"))
        #expect(output.contains("  SBIconView"))

        let headers = try tools.header(["framework": "SpringBoardHome.framework"])
        #expect(headers.hasPrefix("SpringBoardHome.framework (PrivateFrameworks)\n"))
        #expect(headers.contains("has no headers in this SDK"))
        #expect(headers.contains("declare the interface you call in a local header"))
    }

    @Test
    func `the folder private names is tried first, then the other`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let uikit = try tools.analyze(["framework": "UIKit", "private": true])
        #expect(uikit.hasPrefix("UIKit.framework (Frameworks; not in PrivateFrameworks)\n"))
        #expect(uikit.contains("install name: /System/Library/Frameworks/UIKit.framework/UIKit"))

        let home = try tools.analyze(["framework": "SpringBoardHome", "private": false])
        #expect(home.hasPrefix("SpringBoardHome.framework (PrivateFrameworks; not in Frameworks)\n"))

        let vision = try tools.analyze(["framework": "Vision"])
        #expect(vision.hasPrefix("Vision.framework (Frameworks)\n"))
    }

    @Test
    func `an unknown framework is named with similar ones`() {
        defer { try? FileManager.default.removeItem(at: base) }
        let similar = message { try tools.analyze(["framework": "SpringBoardHom"]) }
        #expect(similar == "No framework named SpringBoardHom in Frameworks or PrivateFrameworks of this SDK; similar: SpringBoardHome")

        let reverse = message { try tools.header(["framework": "springboardfoundationkit"]) }
        #expect(reverse?.hasSuffix("similar: SpringBoardFoundation") == true)

        let none = message { try tools.analyze(["framework": "Quux"]) }
        #expect(none?.hasSuffix("none there has a similar name") == true)
    }

    @Test
    func `an SDK without PrivateFrameworks says so`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.removeItem(at: sdkURL.appendingPathComponent("System/Library/PrivateFrameworks"))
        let missing = message { try tools.analyze(["framework": "SpringBoardHome"]) }
        #expect(missing?.hasSuffix("This SDK has no PrivateFrameworks folder") == true)
    }

    // MARK: - The declaring header

    @Test
    func `a header named after a class finds the header that declares it`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let output = try tools.header(["framework": "Vision", "header": "VNFaceObservation.h"])
        #expect(output.hasPrefix("""
        Vision.framework (Frameworks)
        VNFaceObservation.h is not a header of Vision.framework; VNFaceObservation is declared in VNObservation.h:
          7: API_AVAILABLE(ios(11.0)) @interface VNFaceObservation: VNDetectedObjectObservation

        """))
        #expect(output.hasSuffix(Self.observationHeader))
    }

    @Test
    func `symbol finds the headers that declare a name`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let face = try tools.header(["framework": "Vision", "symbol": "VNFaceObservation"])
        #expect(face.contains("VNFaceObservation is declared in VNObservation.h:\n"))
        #expect(face.hasSuffix(Self.observationHeader))

        // A superclass, a parameter or a property's type does not declare it.
        let observation = try tools.header(["framework": "Vision", "symbol": "VNObservation"])
        #expect(observation.contains("VNObservation is declared in VNObservation.h:\n  4: @interface VNObservation : NSObject\n\n"))

        let level = try tools.header(["framework": "Vision", "symbol": "VNRequestTrackingLevel"])
        #expect(level.contains("VNRequestTrackingLevel is declared in VNRequest.h:\n  3: typedef NS_ENUM(NSUInteger, VNRequestTrackingLevel) {\n"))

        let function = try tools.header(["framework": "Vision", "symbol": "VNNormalizedRectForImageRect"])
        #expect(function.contains("declared in VNRequest.h:\n  12: VN_EXPORT CGRect VNNormalizedRectForImageRect(CGRect imageRect, size_t width);\n"))

        let constant = try tools.header(["framework": "Vision", "symbol": "VNImageOptionProperties"])
        #expect(constant.contains("declared in VNRequest.h:\n  10: VN_EXPORT VNImageOption const VNImageOptionProperties API_AVAILABLE(ios(11.0));\n"))

        let handler = try tools.header(["framework": "Vision", "symbol": "VNRequestCompletionHandler"])
        #expect(handler.contains("declared in VNRequest.h:\n  8: typedef void (^VNRequestCompletionHandler)(VNRequest *request, NSError *error);\n"))

        let protocolName = try tools.header(["framework": "Vision", "symbol": "VNFaceObservationAccepting"])
        #expect(protocolName.contains("declared in VNRequest.h:\n  14: @protocol VNFaceObservationAccepting <NSObject>\n"))

        let enumCase = try tools.header(["framework": "Vision", "symbol": "VNRequestTrackingLevelAccurate"])
        #expect(enumCase.contains("declared in VNRequest.h:\n  4: VNRequestTrackingLevelAccurate = 0,\n"))

        let pure = try tools.header(["framework": "Vision", "symbol": "VNConfidenceAverage"])
        #expect(pure.contains("declared in VNRequest.h:\n  21: VN_EXPORT VNConfidence VN_PURE VNConfidenceAverage("))
    }

    @Test
    func `a comment declares nothing`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let commented = try tools.header(["framework": "Vision", "symbol": "VNRequestTrackingLevelFast"])
        #expect(commented.hasSuffix("VNRequestTrackingLevelFast is not declared in the headers of Vision.framework; apelin_sdk_analyze_framework with symbol_filter shows whether its .tbd exports it"))

        var inComment = false
        #expect(HeaderDeclarations.code(of: "int a; /* b */ int c; // d", inComment: &inComment) == "int a;   int c; ")
        #expect(HeaderDeclarations.code(of: "x /* open", inComment: &inComment) == "x  ")
        #expect(inComment)
        #expect(HeaderDeclarations.code(of: "still // inside", inComment: &inComment) == "")
        #expect(HeaderDeclarations.code(of: "*/ y", inComment: &inComment) == " y")
        #expect(!inComment)
    }

    @Test
    func `a long list of declarations is cut short`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let many = Array(repeating: "typedef int VNMany;", count: 45).joined(separator: "\n")
        try many.write(
            to: sdkURL.appendingPathComponent("System/Library/Frameworks/Vision.framework/Headers/VNMany.h"),
            atomically: true,
            encoding: .utf8,
        )
        let output = try tools.header(["framework": "Vision", "symbol": "VNMany"])
        #expect(output.contains("VNMany is declared in VNMany.h:\n  1: typedef int VNMany;\n"))
        #expect(output.contains("\n  40: typedef int VNMany;\n  … 5 more\n\n" + many))
        #expect(!output.contains("  41: "))
    }

    @Test
    func `a header name without its extension is looked up the same way`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let output = try tools.header(["framework": "Vision", "header": "VNFaceObservation"])
        #expect(output.hasPrefix("""
        Vision.framework (Frameworks)
        VNFaceObservation is not a header of Vision.framework; VNFaceObservation is declared in VNObservation.h:
        """))
    }

    @Test
    func `a name declared in several headers lists them all`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let output = try tools.header(["framework": "Vision", "symbol": "VNConfidence"])
        #expect(output == """
        Vision.framework (Frameworks)
        VNConfidence is declared in 2 headers; read one with header:
          VNObservation.h:2: typedef float VNConfidence;
          VNRequest.h:1: typedef float VNConfidence;
        """)
    }

    @Test
    func `a name nothing declares lists the headers or points to the stub`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let header = try tools.header(["framework": "Vision", "header": "VNMissing.h"])
        #expect(header == """
        Vision.framework (Frameworks)
        VNMissing.h is not a header of Vision.framework; its headers are:
        VNObservation.h
        VNRequest.h
        VNSecret.h
        """)

        let symbol = try tools.header(["framework": "Vision", "symbol": "VNMissing"])
        #expect(symbol.hasSuffix("VNMissing is not declared in the headers of Vision.framework; apelin_sdk_analyze_framework with symbol_filter shows whether its .tbd exports it"))

        let existing = try tools.header(["framework": "Vision", "header": "VNRequest.h"])
        #expect(existing == "Vision.framework (Frameworks)\n" + Self.requestHeader)
    }

    @Test
    func `a header that links out of the SDK is never read`() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = try tools.header(["framework": "Vision", "symbol": "VNSecretObservation"])
        #expect(secret.contains("VNSecretObservation is not declared in the headers of Vision.framework"))

        let direct = message { try tools.header(["framework": "Vision", "header": "VNSecret.h"]) }
        #expect(direct?.contains("is outside") == true)

        let guessed = try tools.header(["framework": "Vision", "header": "VNSecretObservation.h"])
        #expect(!guessed.contains("@interface VNSecretObservation"))
    }

    @Test
    func `symbol and header together, or a symbol that is no name, are refused`() {
        defer { try? FileManager.default.removeItem(at: base) }
        let both = message { try tools.header(["framework": "Vision", "header": "VNRequest.h", "symbol": "VNRequest"]) }
        #expect(both == "pass header or symbol, not both")

        let notAName = message { try tools.header(["framework": "Vision", "symbol": "VN.*"]) }
        #expect(notAName == "symbol must be a C or Objective-C name, like VNFaceObservation")
    }

    // MARK: - Stubs

    @Test
    func `a v4 YAML stub keeps exports and leaves undefineds out`() {
        defer { try? FileManager.default.removeItem(at: base) }
        let stub = TBDStub.parse(Self.stub(for: "PrivateFrameworks/SpringBoardHome"))
        #expect(stub.installName == "/System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome")
        #expect(stub.currentVersion == "1.0")
        #expect(stub.targets == ["arm64-ios", "arm64e-ios"])
        #expect(stub.symbols == ["_SBHIconGridSizeClassDefault", "_SBHWeakSymbol"])
        #expect(stub.objcClasses == ["SBIconListView", "SBIconView"])
    }

    @Test
    func `a v5 JSON stub reads its main library`() {
        defer { try? FileManager.default.removeItem(at: base) }
        let stub = TBDStub.parse(Self.visionStub)
        #expect(stub.installName == "/System/Library/Frameworks/Vision.framework/Vision")
        #expect(stub.currentVersion == "8.0.0")
        #expect(stub.targets == ["arm64-ios", "arm64e-ios"])
        #expect(stub.reexports == ["/usr/lib/libVisionCore.dylib"])
        #expect(stub.symbols == ["_VNImageOptionProperties", "_VNNormalizedRectForImageRect", "_VNWeakSymbol"])
        #expect(stub.objcClasses == ["VNFaceObservation", "VNObservation"])
    }

    // MARK: - Fixtures

    static func stub(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return """
        --- !tapi-tbd
        tbd-version:     4
        targets:         [ arm64-ios, arm64e-ios ]
        install-name:    '/System/Library/\(path).framework/\(name)'
        current-version: 1.0
        exports:
          - targets:         [ arm64-ios, arm64e-ios ]
            symbols:         [ _SBHIconGridSizeClassDefault ]
            weak-symbols:    [ _SBHWeakSymbol ]
            objc-classes:    [ SBIconListView, SBIconView ]
        undefineds:
          - targets:         [ arm64-ios, arm64e-ios ]
            symbols:         [ _objc_msgSend ]
        ...

        """
    }

    static let visionStub = """
    {
      "tapi_tbd_version": 5,
      "main_library": {
        "target_info": [{"target": "arm64-ios", "min_deployment": "16.0"}, {"target": "arm64e-ios", "min_deployment": "16.0"}],
        "install_names": [{"name": "/System/Library/Frameworks/Vision.framework/Vision"}],
        "current_versions": [{"version": "8.0.0"}],
        "reexported_libraries": [{"names": ["/usr/lib/libVisionCore.dylib"]}],
        "exported_symbols": [{
          "data": {"global": ["_VNImageOptionProperties"], "objc_class": ["VNFaceObservation", "VNObservation"]},
          "text": {"global": ["_VNNormalizedRectForImageRect"], "weak": ["_VNWeakSymbol"]}
        }]
      }
    }
    """

    /// The class VNFaceObservation is declared here, not in a header of its
    /// own name; the other lines only use the names.
    static let observationHeader = """
    #import <Foundation/Foundation.h>
    typedef float VNConfidence;
    @class VNFaceObservation;
    @interface VNObservation : NSObject
    @property (readonly) VNConfidence confidence;
    @end
    API_AVAILABLE(ios(11.0)) @interface VNFaceObservation: VNDetectedObjectObservation
    @end
    @interface VNFaceObservation (VNExtras)
    - (void)compareWith:(VNObservation *)other;
    @end

    """

    static let requestHeader = """
    typedef float VNConfidence;
    @protocol VNFaceObservationAccepting;
    typedef NS_ENUM(NSUInteger, VNRequestTrackingLevel) {
        VNRequestTrackingLevelAccurate = 0,
    };
    typedef NSString *VNImageOption NS_TYPED_ENUM;
    @class VNRequest;
    typedef void (^VNRequestCompletionHandler)(VNRequest *request, NSError *error);
    /* VNFaceObservation results come back to the handler. */
    VN_EXPORT VNImageOption const VNImageOptionProperties API_AVAILABLE(ios(11.0));
    @interface VNImageRequest : VNRequest <VNFaceObservationAccepting>
    VN_EXPORT CGRect VNNormalizedRectForImageRect(CGRect imageRect, size_t width);
    @end
    @protocol VNFaceObservationAccepting <NSObject>
    @property (copy) NSArray<VNFaceObservation *> *inputFaceObservations;
    @end
    /*!
        VNRequestTrackingLevelFast,
     */
    // VNNormalizedRectForImageRect(CGRect rect);
    VN_EXPORT VNConfidence VN_PURE VNConfidenceAverage(VNConfidence a, VNConfidence b);

    """
}
