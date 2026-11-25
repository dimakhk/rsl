import Foundation

enum CloudCredential {
    static func read() -> String? {
        guard let file = Bundle.main.url(forResource: "cloud-token", withExtension: "txt"),
              let value = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil ? token : nil
    }
}
