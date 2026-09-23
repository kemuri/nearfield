import Foundation

struct RouterDriverUpdate: Equatable, Sendable {
    let installedVersion: String?
    let availableVersion: String
    let bundledDriverURL: URL
}

/// Driver builds use numeric CFBundleVersion values, independently of app releases.
struct RouterDriverVersion: Equatable, Comparable {
    private let components: [UInt]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [UInt] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt(part) else { return nil }
            numbers.append(number)
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
