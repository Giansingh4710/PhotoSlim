import Foundation

enum StorageSafety {
    static let reserveBytes: Int64 = 500 * 1_024 * 1_024

    /// Unknown capacity or overflowing estimates must stop work, never bypass it.
    static func hasHeadroom(free: Int64?, bytes: Int64, copies: Int64 = 2) -> Bool {
        guard let free, free >= reserveBytes, bytes > 0, copies > 0 else { return false }
        let (working, overflow) = bytes.multipliedReportingOverflow(by: copies)
        guard !overflow else { return false }
        return working <= free - reserveBytes
    }
}
