import Foundation

public enum WireDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    public static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = try? fractional.parse(text) { return date }
        if let date = try? whole.parse(text) { return date }
        return parseWithArbitraryFraction(text)
    }

    public static func format(_ date: Date) -> String {
        whole.format(date)
    }

    private static func parseWithArbitraryFraction(_ text: String) -> Date? {
        guard let match = text.firstMatch(of: /^(.+T\d{2}:\d{2}:\d{2})\.(\d+)(Z|[+-]\d{2}:?\d{2})$/) else {
            return nil
        }
        guard let base = try? whole.parse("\(match.1)\(match.3)") else { return nil }
        let fraction = Double("0.\(match.2)") ?? 0
        return base.addingTimeInterval(fraction)
    }
}

public extension JSONDecoder {
    static func wire() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = WireDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised timestamp \(raw)")
            }
            return date
        }
        return decoder
    }
}

public extension JSONEncoder {
    static func wire() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(WireDate.format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension KeyedDecodingContainer {
    func lenientDate(_ key: Key) -> Date? {
        guard let raw = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return WireDate.parse(raw)
    }

    func lenientInt(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(exactly: value.rounded(.towardZero)) }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int64(text) }
        return nil
    }

    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil
    }
}
