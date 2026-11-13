import Foundation
import Security
import SwiftUI

enum CloudCredential {
    static let service = "io.github.dimakhk.rsl.cloud"
    static var endpoint: String {
        if let saved = UserDefaults.standard.string(forKey: "cloudEndpoint") { return saved }
        guard let file = Bundle.main.url(forResource: "server", withExtension: "json"),
              let data = try? Data(contentsOf: file) else { return "" }
        return Cloud.parse(data)?.url.absoluteString ?? ""
    }

    static func read(host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: host,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(token: String, host: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: host
        ]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

struct CloudSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = CloudCredential.endpoint
    @State private var token = ""
    @State private var error: String?
    var onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Text("При подключении к серверу кадры камеры отправляются на указанный адрес. Без ключа используется модель на iPhone.")
                TextField("Адрес wss://…", text: $endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Ключ доступа", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Ключ выдаёт владелец сервера. Очистите поле ключа, чтобы отключить облачное распознавание.")
                if let error = error { Text(error).foregroundStyle(.red) }
                Button("Сохранить") {
                    guard let url = URL(string: endpoint), url.scheme == "wss",
                          let host = url.host, url.user == nil, url.password == nil else {
                        error = "Укажите защищённый адрес wss:// без логина и пароля."
                        return
                    }
                    let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard clean.isEmpty || (clean.count >= 32 && clean.count <= 256 &&
                        clean.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) &&
                            !CharacterSet.controlCharacters.contains($0) }) else {
                        error = "Проверьте ключ доступа."
                        return
                    }
                    guard CloudCredential.save(token: clean, host: host) else {
                        error = "Не удалось сохранить ключ в защищённом хранилище."
                        return
                    }
                    UserDefaults.standard.set(endpoint, forKey: "cloudEndpoint")
                    onSaved()
                    dismiss()
                }
            }
            .navigationTitle("Облачный сервер")
            .toolbar { Button("Закрыть") { dismiss() } }
            .onAppear {
                if let host = URL(string: endpoint)?.host { token = CloudCredential.read(host: host) ?? "" }
            }
        }
    }
}
