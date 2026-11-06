import Foundation

/// A one-line preview for notifications and digests. Markdown markers are rendered away;
/// facts such as paths, ids and link text stay. The full text remains in the panel.
enum UpdateText {
    static func short(_ text: String, limit: Int = 190) -> String {
        let plain = ReplyBlock.parse(text).map { block -> String in
            let inline = block.kind == .code ? block.text : (try? AttributedString(markdown: block.text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? block.text
            return block.kind == .bullet ? (block.marker ?? "•") + " " + inline : inline
        }.joined(separator: " ")
        let cleaned = plain.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        let clipped = String(cleaned.prefix(limit))
        if let stop = clipped.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }),
           clipped.distance(from: clipped.startIndex, to: stop) > 60 {
            return String(clipped[...stop])
        }
        return clipped.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A small block layout around Foundation's inline Markdown renderer.
struct ReplyBlock: Equatable {
    enum Kind { case paragraph, heading, bullet, code }
    let kind: Kind
    let text: String
    var marker: String? = nil

    static func parse(_ text: String) -> [ReplyBlock] {
        var blocks: [ReplyBlock] = []
        var buffer: [String] = []
        var inCode = false
        func flush() {
            guard !buffer.isEmpty else { return }
            blocks.append(ReplyBlock(kind: inCode ? .code : .paragraph, text: buffer.joined(separator: "\n")))
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                inCode.toggle()
            } else if inCode { buffer.append(line) }
            else if trimmed.isEmpty { flush() }
            else if let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                blocks.append(ReplyBlock(kind: .heading, text: String(trimmed[range.upperBound...])))
            } else if let range = trimmed.range(of: #"^([-*+] |[0-9]+[.)] )"#, options: .regularExpression) {
                flush()
                let prefix = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                blocks.append(ReplyBlock(kind: .bullet, text: String(trimmed[range.upperBound...]),
                                         marker: prefix.first?.isNumber == true ? prefix : "•"))
            } else { buffer.append(line) }
        }
        flush()
        return blocks
    }
}

/// Plain text stays plain; only detected links become tappable.
enum LinkedText {
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}
