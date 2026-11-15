import Foundation

enum ProviderJSON {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !isBoolean(number) {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = value as? String, let double = Double(text.trimmingCharacters(in: .whitespaces)), double.isFinite {
            return double
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber, !isBoolean(number) {
            return number.stringValue
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, isBoolean(number) { return number.boolValue }
        if let text = (value as? String)?.lowercased() {
            if ["true", "1", "yes"].contains(text) { return true }
            if ["false", "0", "no"].contains(text) { return false }
        }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
        }
        return string(value).flatMap(WireDate.parse)
    }

    static func first(_ object: [String: Any], _ keys: String...) -> Any? {
        for key in keys {
            if let value = object[key], !(value is NSNull) { return value }
        }
        return nil
    }

    static func wholeNumber(_ value: Double, in range: ClosedRange<Int> = 0...Int(Int32.max)) throws -> Int {
        guard let whole = Int(exactly: value.rounded(.towardZero)), range.contains(whole) else { throw UpstreamFailure.unreadable }
        return whole
    }

    static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "c"
    }
}

public enum PlanLabel {
    public static func display(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first, first.isLetter else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
