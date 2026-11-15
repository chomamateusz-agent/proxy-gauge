import Foundation
import Testing
@testable import ProxyGaugeCore

@Suite("Deep links")
struct DeepLinkTests {
    let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    @Test func serverOverviewRoundTrips() throws {
        let url = try #require(DeepLink.serverOverview(id).url(scheme: "proxygauge"))
        #expect(url.absoluteString == "proxygauge://server/6F9619FF-8B86-D011-B42D-00C04FC964FF/overview")
        #expect(DeepLink(url: url, scheme: "proxygauge") == .serverOverview(id))
    }

    @Test(arguments: [
        "otherapp://server/6F9619FF-8B86-D011-B42D-00C04FC964FF/overview",
        "proxygauge://server/not-a-uuid/overview",
        "proxygauge://server/6F9619FF-8B86-D011-B42D-00C04FC964FF/accounts",
        "proxygauge://settings"
    ])
    func foreignOrMalformedLinksAreIgnored(text: String) throws {
        #expect(DeepLink(url: try #require(URL(string: text)), scheme: "proxygauge") == nil)
    }
}
