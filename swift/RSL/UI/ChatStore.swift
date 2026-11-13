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

    /* `persistent: false` keeps nothing on disk (tests, screenshots). */
    init(persistent: Bool) {
        if persistent, let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            file = dir.appendingPathComponent("chats.json")
        } else {
            file = nil
        }
    }

    /* The chats that have something in them, oldest first. */
    func load() -> [StoredChat] {
        guard let file = file, let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let chats = (try? decoder.decode([StoredChat].self, from: data)) ?? []
        return chats.filter { !$0.isEmpty }.sorted { $0.started < $1.started }
    }

    func save(_ chats: [StoredChat]) {
        guard let file = file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(chats.filter { !$0.isEmpty }) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
