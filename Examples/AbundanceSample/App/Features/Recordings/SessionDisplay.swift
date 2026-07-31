import Foundation

/// Human naming for device session ids, shared by the library and the
/// on-camera list. Ids are `YYYY_MM_DD_HH_MM_SS_<suffix>` (start time in the
/// name) or the newer `s<number>_<suffix>` (opaque).
enum SessionDisplay {
    static func startDate(fromID id: String) -> Date? {
        guard id.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy_MM_dd_HH_mm_ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(id.prefix(19)))
    }

    static func title(forID id: String) -> String {
        guard let date = startDate(fromID: id) else { return "Session \(id.prefix(12))" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
