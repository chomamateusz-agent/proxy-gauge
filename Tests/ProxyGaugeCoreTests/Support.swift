import Foundation
@testable import ProxyGaugeCore

final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    convenience init(routes: [String: HTTPResponse]) {
        self.init { request in
            let key = "\(request.method.rawValue) \(request.url.path())"
            return routes[key] ?? HTTPResponse(statusCode: 404, body: Data("404 page not found".utf8))
        }
    }

    var requests: [HTTPRequest] { lock.withLock { recorded } }

    var managementRequestCount: Int { requests.filter { $0.url.path().contains("/v8/management/") }.count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        return try handler(request)
    }
}

enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "docs/fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }

    static func response(_ name: String, status: Int = 200, headers: [String: String] = [:]) throws -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: try data(name))
    }
}

extension HTTPResponse {
    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data(text.utf8))
    }
}

let stockVersionHeaders = [
    "X-CPA-VERSION": "8.0.69",
    "X-CPA-COMMIT": "f7ae8fee",
    "X-CPA-BUILD-DATE": "2026-11-12T18:27:10Z",
    "X-CPA-SUPPORT-PLUGIN": "1"
]

let testBaseURL = URL(string: "http://192.168.1.20:8317")!

func date(_ text: String) -> Date {
    WireDate.parse(text)!
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
