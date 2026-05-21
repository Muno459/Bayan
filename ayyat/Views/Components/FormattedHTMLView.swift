import SwiftUI

/// Renders a chunk of Quran Foundation API HTML (tafsir, chapter info)
/// as proper SwiftUI blocks: paragraph spacing, headers, blockquotes,
/// bullet lists, em / strong inline emphasis, Arabic spans honoured.
///
/// We intentionally avoid `NSAttributedString(data:options:.html)` —
/// it pulls in WebKit, is main-thread-only, and inherits font/size from
/// the document attributes so it can't be themed cleanly. Instead we
/// do a small regex-driven HTML → block-tree pass.
struct FormattedHTMLView: View {
    let html: String

    private var blocks: [HTMLBlock] {
        HTMLBlockParser.parse(html)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func view(for block: HTMLBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(text)
                .font(.system(
                    size: level == 1 ? 22 : level == 2 ? 19 : 16,
                    weight: level <= 2 ? .bold : .semibold
                ))
                .foregroundStyle(AyyatColors.primary)
                .padding(.top, 4)

        case .paragraph(let text):
            Text(text)
                .font(.system(size: 16))
                .lineSpacing(5)
                .foregroundStyle(AyyatColors.textPrimary)

        case .arabicQuote(let text):
            // Centered, slightly larger, RTL, distinct background — matches
            // how quran.com sets apart in-tafsir Arabic verse quotes.
            Text(text)
                .font(.system(size: 20))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .environment(\.layoutDirection, .rightToLeft)
                .foregroundStyle(AyyatColors.primary.opacity(0.9))
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AyyatColors.primary.opacity(0.06))
                )

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(AyyatColors.primary.opacity(0.35))
                    .frame(width: 3)
                Text(text)
                    .font(.system(size: 15))
                    .italic()
                    .lineSpacing(4)
                    .foregroundStyle(AyyatColors.textSecondary)
            }

        case .listItem(let text, let ordered, let index):
            HStack(alignment: .top, spacing: 10) {
                Text(ordered ? "\(index)." : "•")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AyyatColors.primary.opacity(0.7))
                    .frame(width: 18, alignment: .leading)
                Text(text)
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .foregroundStyle(AyyatColors.textPrimary)
            }
        }
    }
}

// MARK: - Block model

struct HTMLBlock: Identifiable {
    let id: UUID
    let kind: Kind

    enum Kind {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case arabicQuote(AttributedString)
        case blockquote(AttributedString)
        case listItem(text: AttributedString, ordered: Bool, index: Int)
    }

    static func heading(level: Int, text: AttributedString) -> HTMLBlock {
        HTMLBlock(id: UUID(), kind: .heading(level: level, text: text))
    }
    static func paragraph(_ text: AttributedString) -> HTMLBlock {
        HTMLBlock(id: UUID(), kind: .paragraph(text))
    }
    static func arabicQuote(_ text: AttributedString) -> HTMLBlock {
        HTMLBlock(id: UUID(), kind: .arabicQuote(text))
    }
    static func blockquote(_ text: AttributedString) -> HTMLBlock {
        HTMLBlock(id: UUID(), kind: .blockquote(text))
    }
    static func listItem(text: AttributedString, ordered: Bool, index: Int) -> HTMLBlock {
        HTMLBlock(id: UUID(), kind: .listItem(text: text, ordered: ordered, index: index))
    }
}

// MARK: - Parser

enum HTMLBlockParser {

    static func parse(_ html: String) -> [HTMLBlock] {
        var s = unescape(html)

        // Inline first — em / strong become markdown so AttributedString
        // can render them. <br> becomes a soft newline so they survive
        // the block-tag pass.
        s = replace(s, pattern: "<\\s*br\\s*/?\\s*>", with: "\n")
        s = wrap(s, tag: "em", with: "*", "*")
        s = wrap(s, tag: "i",  with: "*", "*")
        s = wrap(s, tag: "strong", with: "**", "**")
        s = wrap(s, tag: "b",  with: "**", "**")

        // Block tags get carved out with delimiters so we can split on them.
        // The delimiters are private-use unicode so they won't collide
        // with normal text.
        let openH1  = "\u{E001}H1\u{E002}"
        let closeH1 = "\u{E001}/H1\u{E002}"
        let openH2  = "\u{E001}H2\u{E002}"
        let closeH2 = "\u{E001}/H2\u{E002}"
        let openH3  = "\u{E001}H3\u{E002}"
        let closeH3 = "\u{E001}/H3\u{E002}"
        let openP   = "\u{E001}P\u{E002}"
        let closeP  = "\u{E001}/P\u{E002}"
        let openBQ  = "\u{E001}BQ\u{E002}"
        let closeBQ = "\u{E001}/BQ\u{E002}"
        let openLI  = "\u{E001}LI\u{E002}"
        let closeLI = "\u{E001}/LI\u{E002}"

        s = replace(s, pattern: "<\\s*h1[^>]*>", with: openH1)
        s = replace(s, pattern: "</\\s*h1\\s*>",  with: closeH1)
        s = replace(s, pattern: "<\\s*h2[^>]*>", with: openH2)
        s = replace(s, pattern: "</\\s*h2\\s*>",  with: closeH2)
        s = replace(s, pattern: "<\\s*h[3-6][^>]*>", with: openH3)
        s = replace(s, pattern: "</\\s*h[3-6]\\s*>",  with: closeH3)
        s = replace(s, pattern: "<\\s*p[^>]*>",  with: openP)
        s = replace(s, pattern: "</\\s*p\\s*>",   with: closeP)
        s = replace(s, pattern: "<\\s*blockquote[^>]*>", with: openBQ)
        s = replace(s, pattern: "</\\s*blockquote\\s*>",  with: closeBQ)
        s = replace(s, pattern: "<\\s*li[^>]*>", with: openLI)
        s = replace(s, pattern: "</\\s*li\\s*>",  with: closeLI)

        // Strip any remaining tags (ul/ol wrappers, span class="...", anchors, etc.)
        s = replace(s, pattern: "<[^>]+>", with: "")

        // Walk forward, peeling off [openTag ... closeTag] blocks. Anything
        // outside a known block tag falls into a "loose" paragraph.
        var blocks: [HTMLBlock] = []
        var olCounter = 1
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = nil

        func appendIfMeaningful(_ raw: String, as factory: (AttributedString) -> HTMLBlock?) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Arabic-only loose text gets the verse-quote treatment too —
            // QF tafsirs sometimes emit Arabic Hadith blocks outside of <p>.
            if isPredominantlyArabic(trimmed) {
                blocks.append(.arabicQuote(AttributedString(trimmed)))
                return
            }
            let attr = (try? AttributedString(markdown: trimmed, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))) ?? AttributedString(trimmed)
            if let block = factory(attr) {
                blocks.append(block)
            }
        }

        let openTags: [(String, String, (String) -> HTMLBlock?)] = [
            (openH1, closeH1, { t in
                guard !t.isEmpty else { return nil }
                let attr = (try? AttributedString(markdown: t)) ?? AttributedString(t)
                return .heading(level: 1, text: attr)
            }),
            (openH2, closeH2, { t in
                guard !t.isEmpty else { return nil }
                let attr = (try? AttributedString(markdown: t)) ?? AttributedString(t)
                return .heading(level: 2, text: attr)
            }),
            (openH3, closeH3, { t in
                guard !t.isEmpty else { return nil }
                let attr = (try? AttributedString(markdown: t)) ?? AttributedString(t)
                return .heading(level: 3, text: attr)
            }),
            (openP, closeP, { t in
                guard !t.isEmpty else { return nil }
                // Arabic-heavy paragraphs get the verse-quote treatment.
                if isPredominantlyArabic(t) {
                    return .arabicQuote(AttributedString(t))
                }
                let attr = (try? AttributedString(markdown: t, options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                ))) ?? AttributedString(t)
                return .paragraph(attr)
            }),
            (openBQ, closeBQ, { t in
                guard !t.isEmpty else { return nil }
                let attr = (try? AttributedString(markdown: t)) ?? AttributedString(t)
                return .blockquote(attr)
            }),
            (openLI, closeLI, { t in
                guard !t.isEmpty else { return nil }
                let attr = (try? AttributedString(markdown: t)) ?? AttributedString(t)
                let item = HTMLBlock.listItem(text: attr, ordered: false, index: 0)
                return item
            }),
        ]

        while !scanner.isAtEnd {
            // Find the nearest open tag from here.
            var nextOpenIndex: String.Index?
            var nextOpenTag: String?
            var nextClose: String?
            var nextFactory: ((String) -> HTMLBlock?)?
            for (open, close, factory) in openTags {
                if let r = s.range(of: open, range: scanner.currentIndex..<s.endIndex) {
                    if nextOpenIndex == nil || r.lowerBound < nextOpenIndex! {
                        nextOpenIndex = r.lowerBound
                        nextOpenTag = open
                        nextClose = close
                        nextFactory = factory
                    }
                }
            }

            if let openIdx = nextOpenIndex, let openTag = nextOpenTag,
               let closeTag = nextClose, let factory = nextFactory {
                // Anything between current scan position and the open tag
                // is loose text — render as a paragraph.
                if openIdx > scanner.currentIndex {
                    let loose = String(s[scanner.currentIndex..<openIdx])
                    appendIfMeaningful(loose) { .paragraph($0) }
                }
                let afterOpen = s.index(openIdx, offsetBy: openTag.count)
                if let closeRange = s.range(of: closeTag, range: afterOpen..<s.endIndex) {
                    let inner = String(s[afterOpen..<closeRange.lowerBound])
                    let cleaned = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let block = factory(cleaned) {
                        // Patch ordered-list index if this was a list item
                        if case .listItem(let txt, _, _) = block.kind {
                            blocks.append(.listItem(text: txt, ordered: false, index: olCounter))
                            olCounter += 1
                        } else {
                            blocks.append(block)
                            olCounter = 1  // reset between non-list blocks
                        }
                    }
                    scanner.currentIndex = s.index(closeRange.lowerBound, offsetBy: closeTag.count)
                } else {
                    // Unclosed tag — give up cleanly.
                    let remainder = String(s[afterOpen...])
                    appendIfMeaningful(remainder) { .paragraph($0) }
                    break
                }
            } else {
                // No more tags — flush trailing text as paragraph.
                let trailing = String(s[scanner.currentIndex...])
                appendIfMeaningful(trailing) { .paragraph($0) }
                break
            }
        }

        return blocks
    }

    // MARK: - Helpers

    private static func unescape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&nbsp;",  with: " ")
            .replacingOccurrences(of: "&amp;",   with: "&")
            .replacingOccurrences(of: "&quot;",  with: "\"")
            .replacingOccurrences(of: "&apos;",  with: "'")
            .replacingOccurrences(of: "&#39;",   with: "'")
            .replacingOccurrences(of: "&hellip;",with: "…")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&lsquo;", with: "‘")
            .replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&rdquo;", with: "”")
            .replacingOccurrences(of: "&lt;",    with: "<")
            .replacingOccurrences(of: "&gt;",    with: ">")
            // Ibn Kathir tafsir uses backticks as transliteration apostrophes
            // (e.g. `Ubayy bin Ka`b). AttributedString(markdown:) would
            // treat these as code spans and render in monospace, which
            // looks wrong. Swap to typographic apostrophes.
            .replacingOccurrences(of: "`", with: "\u{2019}")
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
    }

    private static func wrap(_ s: String, tag: String, with open: String, _ close: String) -> String {
        let opened = replace(s, pattern: "<\\s*\(tag)[^>]*>", with: open)
        return replace(opened, pattern: "</\\s*\(tag)\\s*>", with: close)
    }

    /// Quick check whether a paragraph is mostly Arabic Quran text.
    /// Counts unicode points in the Arabic range vs total non-space.
    private static func isPredominantlyArabic(_ s: String) -> Bool {
        var arabic = 0, total = 0
        for scalar in s.unicodeScalars where !CharacterSet.whitespaces.contains(scalar) {
            total += 1
            if (0x0600...0x06FF).contains(scalar.value) || (0xFB50...0xFDFF).contains(scalar.value) {
                arabic += 1
            }
        }
        return total > 0 && Double(arabic) / Double(total) > 0.6
    }
}
