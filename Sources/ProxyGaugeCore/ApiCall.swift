import Foundation

public struct UpstreamCall: Sendable, Equatable {
    public var authIndex: String
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var data: String?

    public init(authIndex: String, method: HTTPMethod = .get, url: URL, headers: [String: String], data: String? = nil) {
        self.authIndex = authIndex
        self.method = method
        self.url = url
        self.headers = headers
        self.data = data
    }

    var envelope: [String: Any] {
        var payload: [String: Any] = [
            "authIndex": authIndex,
            "method": method.rawValue,
            "url": url.absoluteString,
            "header": headers
        ]
        if let data { payload["data"] = data }
        return payload
    }
}

public struct UpstreamReply: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: [String]]
    public var body: Data

    public init(statusCode: Int, headers: [String: [String]] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value.first
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    public var json: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

struct ApiCallEnvelope: Decodable {
    var statusCode: Int
    var header: [String: [String]]
    var body: String

    enum CodingKeys: String, CodingKey {
        case header, body
        case statusCode = "status_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = Int(container.lenientInt(.statusCode) ?? 0)
        header = (try? container.decodeIfPresent([String: [String]].self, forKey: .header)) ?? [:]
        body = container.lenientString(.body) ?? ""
    }
}

public enum UpstreamFailure: Error, Equatable, Sendable {
    case rateLimited(retryAfter: Date?)
    case rejected(status: Int)
    case upstream(status: Int)
    case unreadable

    public static func classify(_ reply: UpstreamReply, now: Date) -> UpstreamFailure? {
        switch reply.statusCode {
        case 200..<300: nil
        case 429: .rateLimited(retryAfter: RetryAfter.date(reply.header("Retry-After"), now: now))
        case 401, 403: .rejected(status: reply.statusCode)
        default: .upstream(status: reply.statusCode)
        }
    }

    public var stopsTheRefresh: Bool {
        switch self {
        case .rateLimited, .rejected: true
        case .upstream, .unreadable: false
        }
    }
}

public enum RetryAfter {
    private static let httpDateFormats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"]
    public static let longestCredible: TimeInterval = 366 * 86_400

    public static func date(_ raw: String?, now: Date) -> Date? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let seconds = Double(text) {
            guard seconds.isFinite, seconds > 0, seconds <= longestCredible else { return nil }
            return now.addingTimeInterval(seconds)
        }
        guard let date = httpDate(text), date > now, date.timeIntervalSince(now) <= longestCredible else { return nil }
        return date
    }

    private static func httpDate(_ text: String) -> Date? {
        for format in httpDateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

extension ManagementClient {
    public func apiCall(_ call: UpstreamCall, hooks: SendHooks = .none) async throws -> UpstreamReply {
        let body = try JSONSerialization.data(withJSONObject: call.envelope, options: [.sortedKeys])
        let response = try await exchange.send(builder.request(.post, "v8/management/requests/api-call", json: body), hooks: hooks)
        let envelope = try exchange.decode(ApiCallEnvelope.self, from: response)
        return UpstreamReply(statusCode: envelope.statusCode, headers: envelope.header, body: Data(envelope.body.utf8))
    }
}
