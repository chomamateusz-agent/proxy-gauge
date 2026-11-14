import Foundation

public enum APIError: Error, Equatable, Sendable {
    case invalidBaseURL
    case missingCredential
    case credentialUnavailable(String)
    case unauthorized(String?)
    case forbidden(String?)
    case ipBanned(retryAt: Date?)
    case notFound(String?)
    case conflict(String?)
    case preconditionFailed
    case server(status: Int, message: String?)
    case decoding(String)
    case transport(String)
    case pausedBeforeSending(AuthPauseReason)

    public var serverMessage: String? {
        switch self {
        case .unauthorized(let message), .forbidden(let message), .notFound(let message), .conflict(let message):
            message
        case .server(_, let message):
            message
        case .decoding(let detail), .transport(let detail), .credentialUnavailable(let detail):
            detail
        case .invalidBaseURL, .missingCredential, .preconditionFailed, .ipBanned, .pausedBeforeSending:
            nil
        }
    }

    public var isRemoteManagementDisabled: Bool {
        if case .forbidden(let message) = self {
            return message == "remote management disabled"
        }
        return false
    }

    public var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized, .ipBanned: true
        case .forbidden: !isRemoteManagementDisabled
        default: false
        }
    }

    public static func wrapping(_ error: any Error) -> APIError {
        error as? APIError ?? .transport(error.localizedDescription)
    }

    static func from(_ response: HTTPResponse, receivedAt: Date = Date()) -> APIError {
        let message = ErrorBody.message(in: response.body)
        switch response.statusCode {
        case 401: return .unauthorized(message)
        case 403: return IPBanNotice(message).map { .ipBanned(retryAt: $0.retryAt(from: receivedAt)) } ?? .forbidden(message)
        case 404: return .notFound(message)
        case 409: return .conflict(message)
        case 412: return .preconditionFailed
        default: return .server(status: response.statusCode, message: message)
        }
    }
}

struct IPBanNotice {
    static let prefix = "IP banned due to too many failed attempts"
    static let remainingMarker = "Try again in "

    let remaining: TimeInterval?

    init?(_ message: String?) {
        guard let message, message.hasPrefix(Self.prefix) else { return nil }
        remaining = message.range(of: Self.remainingMarker).flatMap { GoDuration.seconds(in: String(message[$0.upperBound...])) }
    }

    func retryAt(from receivedAt: Date) -> Date? {
        remaining.map { receivedAt.addingTimeInterval($0) }
    }
}

enum GoDuration {
    private static let unitSeconds: [String: TimeInterval] = ["h": 3600, "m": 60, "s": 1, "ms": 0.001, "us": 0.000_001, "µs": 0.000_001, "ns": 0.000_000_001]

    static func seconds(in text: String) -> TimeInterval? {
        let pattern = /(\d+(?:\.\d+)?)(ms|us|µs|ns|h|m|s)/
        let token = text.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        guard !token.isEmpty, token.wholeMatch(of: /(?:\d+(?:\.\d+)?(?:ms|us|µs|ns|h|m|s))+/) != nil else { return nil }
        return token.matches(of: pattern).reduce(0) { total, match in
            total + (Double(match.output.1) ?? 0) * (unitSeconds[String(match.output.2)] ?? 0)
        }
    }
}

struct ErrorBody: Decodable {
    var error: String?
    var message: String?

    static func message(in data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
            let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return body.message ?? body.error
    }
}
