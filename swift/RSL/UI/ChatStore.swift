import Foundation

/* The chats, kept in the device between runs.

   A chat is its messages and when it was started. Its name is not typed by
   anybody: it is worked out from what was said (ChatTitle). An empty chat is
   never kept - opening the app starts a new chat every time, and without
   that rule the history would fill up with blanks. */

struct StoredChat: Codable, Identifiable, Equatable {
    struct Line: Codable, Equatable {
        var right: Bool                          // a gesture (right) or voice / keyboard (left)
        var text: String
    }

    var id = UUID()
    var started = Date()
    var lines: [Line] = []

    var isEmpty: Bool { lines.isEmpty }
    var title: String { ChatTitle.make(from: lines.map(\.text)) ?? ChatTitle.new }
}

/* A short name for a chat, from its own words.

   No language model is involved (the phone has none to ask): the name is the
   beginning of the first remark that says something - a greeting on its own
   is skipped when there is more after it - cut to a few words. */
enum ChatTitle {
    static let new = "Новый чат"
    static let maxWords = 4
    static let maxLength = 22

    private static let greetings: Set<String> = [
        "привет", "здравствуйте", "здравствуй", "добрый", "доброе", "день", "утро", "вечер", "здрасте", "приветствую",
    ]

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map {
            $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        }.filter { !$0.isEmpty }
    }

    private static func isGreeting(_ words: [String]) -> Bool {
        !words.isEmpty && words.allSatisfy { greetings.contains($0.lowercased()) }
    }

    static func make(from remarks: [String]) -> String? {
        let all = remarks.map(words).filter { !$0.isEmpty }
        guard let first = all.first else { return nil }
        let chosen = all.first { !isGreeting($0) } ?? first
        var title = ""
        for word in chosen.prefix(maxWords) {
            let next = title.isEmpty ? word : title + " " + word
            if next.count > maxLength {
                if title.isEmpty { title = String(word.prefix(maxLength - 1)) + "…" }
                break
            }
            title = next
        }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}

final class ChatStore {
    private let file: URL?
    private let queue = DispatchQueue(label: "rsl.chats", qos: .utility)
    private var writable = true
    private(set) var warning: String?

    init(persistent: Bool) {
        file = persistent ? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first?.appendingPathComponent("chats.json") : nil
    }

    init(file: URL) { self.file = file }

    private func decode(_ url: URL) throws -> [StoredChat] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([StoredChat].self, from: Data(contentsOf: url))
            .filter { !$0.isEmpty }.sorted { $0.started < $1.started }
    }

    func load() -> [StoredChat] {
        guard let file = file else { return [] }
        return queue.sync {
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            do { return try decode(file) } catch {
                // Keep the unreadable original before allowing any replacement.
                do {
                    let recovered = try decode(file.appendingPathExtension("backup"))
                    try FileManager.default.copyItem(at: file,
                        to: file.appendingPathExtension("damaged-" + UUID().uuidString))
                    warning = "История восстановлена из резервной копии. Повреждённый файл сохранён."
                    return recovered
                } catch {
                    writable = false
                    warning = "Не удалось прочитать историю. Исходный файл сохранён. Новые чаты пока не сохраняются."
                    return []
                }
            }
        }
    }

    func save(_ chats: [StoredChat], completion: @escaping (String?) -> Void) {
        queue.async {
            var failure: String?
            do {
                if let file = self.file {
                    guard self.writable else {
                        DispatchQueue.main.async { completion(self.warning) }
                        return
                    }
                    let fm = FileManager.default
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(chats.filter { !$0.isEmpty })
                    if fm.fileExists(atPath: file.path), (try? self.decode(file)) != nil {
                        let old = try Data(contentsOf: file)
                        try old.write(to: file.appendingPathExtension("backup"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    }
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            } catch {
                failure = "Не удалось сохранить историю. Проверьте свободное место на устройстве."
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }
}
