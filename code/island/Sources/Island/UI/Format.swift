import Foundation

enum Fmt {
    /// 31.2 GB -> "31,2 ГБ"
    static func bytes(_ b: UInt64, unit: Bool = true) -> String {
        let gb = Double(b) / 1_073_741_824
        let s: String
        if gb >= 10 { s = String(format: "%.1f", gb) }
        else if gb >= 1 { s = String(format: "%.1f", gb) }
        else { s = String(format: "%.0f", Double(b) / 1_048_576); return s.replacingOccurrences(of: ".", with: ",") + " МБ" }
        var r = s.replacingOccurrences(of: ".", with: ",")
        if r.hasSuffix(",0") { r.removeLast(2) }
        return unit ? r + " ГБ" : r
    }

    /// Process memory: MB below 1 GB, otherwise GB.
    static func bytesShort(_ b: UInt64) -> String {
        let mb = Double(b) / 1_048_576
        if mb < 1024 { return String(format: "%.0f МБ", mb) }
        return bytes(b)
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))%"
    }

    /// "только что", "3 мин", "2 ч", "1 дн"
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "только что" }
        if s < 3600 { return "\(s / 60) мин" }
        if s < 86400 { return "\(s / 3600) ч" }
        return "\(s / 86400) дн"
    }

    static func pressureWord(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: return "норма"
        case .warning: return "повышенное"
        case .critical: return "критичное"
        }
    }
}
