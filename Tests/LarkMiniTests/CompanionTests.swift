import XCTest
@testable import LarkMini

final class CompanionTests: XCTestCase {
    func testURLValidationAcceptsHTTPAndHTTPSOnly() {
        XCTAssertEqual(CompanionConfig.validatedURL("http://100.113.131.96:8090")?.absoluteString,
                       "http://100.113.131.96:8090")
        XCTAssertEqual(CompanionConfig.validatedURL(" https://example.com/companion ")?.absoluteString,
                       "https://example.com/companion")
        XCTAssertNil(CompanionConfig.validatedURL("ftp://example.com"))
        XCTAssertNil(CompanionConfig.validatedURL("javascript:alert(1)"))
        XCTAssertNil(CompanionConfig.validatedURL("example.com"))
        XCTAssertNil(CompanionConfig.validatedURL("https:///missing-host"))
        XCTAssertNil(CompanionConfig.validatedURL("https://user:secret@example.com"))
        XCTAssertNil(CompanionConfig.validatedURL(""))
    }

    func testTargetPathStaysOnTheConfiguredOrigin() {
        let base = URL(string: "http://100.113.131.96:8090")!
        XCTAssertEqual(CompanionConfig.targetURL(base: base, path: "/companion/app/abc/messages/management")?.absoluteString,
                       "http://100.113.131.96:8090/companion/app/abc/messages/management")
        XCTAssertEqual(CompanionConfig.targetURL(base: base, path: "companion/app/abc")?.absoluteString,
                       "http://100.113.131.96:8090/companion/app/abc")
        XCTAssertEqual(CompanionConfig.targetURL(base: base, path: nil), base)
        XCTAssertNil(CompanionConfig.targetURL(base: base, path: "//example.com/elsewhere"))
    }

    func testNavigationAllowsTheOriginAndSignInHosts() {
        let base = URL(string: "http://100.113.131.96:8090")!
        let policy = CompanionNavigationPolicy(baseURL: base, signInHosts: ["outlandish.com"])

        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8090/companion/app/abc")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8090/outlandish/sign-in")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://outlandish.com/sign-in")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://id.outlandish.com/login")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "about:blank")!), .allow)

        let defaults = CompanionNavigationPolicy(baseURL: base)
        XCTAssertEqual(defaults.decision(for: URL(string: "https://open.larksuite.com/open-apis/authen/v1/index")!), .allow)
    }

    func testNavigationSendsOtherLinksToTheBrowser() {
        let policy = CompanionNavigationPolicy(baseURL: URL(string: "http://100.113.131.96:8090")!,
                                               signInHosts: ["outlandish.com"])

        XCTAssertEqual(policy.decision(for: URL(string: "https://example.com/report")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8091/companion")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "https://notoutlandish.com/login")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "mailto:help@example.com")!), .external)
    }
}
