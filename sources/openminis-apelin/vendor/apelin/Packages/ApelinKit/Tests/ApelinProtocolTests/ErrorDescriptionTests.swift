@testable import ApelinProtocol
import Foundation
import XCTest

/// The sentence a reader sees of an error kwwk kept as an NSError's whole
/// `description`.
final class ErrorDescriptionTests: XCTestCase {
    func testATransportFailureIsItsLocalizedDescription() {
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -1009, userInfo: [
            "_kCFStreamErrorCodeKey": 50,
            "_kCFStreamErrorDomainKey": 1,
        ])
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
            NSUnderlyingErrorKey: underlying,
            NSURLErrorFailingURLStringErrorKey: "https://example.com/v1/messages",
        ])
        XCTAssertEqual(
            ErrorDescription.localized(String(describing: error)),
            "The Internet connection appears to be offline.",
        )
    }

    func testAnErrorWithNoUserInfo() {
        XCTAssertEqual(
            ErrorDescription.localized(#"Error Domain=NSURLErrorDomain Code=-1001 "The request timed out.""#),
            "The request timed out.",
        )
    }

    func testAnErrorWithNoDescriptionSaysWhatLocalizedDescriptionWould() {
        let error = NSError(domain: "kCFErrorDomainCFNetwork", code: -1009)
        XCTAssertEqual(ErrorDescription.localized(String(describing: error)), error.localizedDescription)
    }

    func testAnyOtherTextIsLeftAsItIs() {
        for text in [
            "The model provider returned an error. Try again.",
            "Error Domain=",
            #"Error Domain=X Code=one "Words""#,
            #"Error Domain=X Code=1 "Unclosed"#,
            "",
        ] {
            XCTAssertEqual(ErrorDescription.localized(text), text)
        }
    }
}
