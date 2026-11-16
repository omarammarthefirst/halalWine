import Foundation

/// Compares dotted version strings numerically ("11.10" > "11.9", "4.3.0" >= "4.3").
public enum VersionCompare {
    public static func components(_ v: String) -> [Int] {
        v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ a: String, than b: String) -> Bool { compare(a, b) == .orderedDescending }
}
