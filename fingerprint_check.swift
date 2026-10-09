import Foundation

@main struct FingerprintChecks {
    static func main() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let known = try MediaFingerprint.file(url)
        precondition(known == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var bytes = Data(repeating: 0x37, count: 3 * 1_024 * 1_024 + 123)
        try bytes.write(to: url)
        let original = try MediaFingerprint.file(url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: url)
        let modified = try MediaFingerprint.file(url)
        precondition(original != modified)
        print("PASS: production SHA-256 matches a known vector and detects a changed byte across streaming chunks")
    }
}
