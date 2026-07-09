// RichText.swift — Rich-text editing and rendering for notes and agent messages.
//
// Notes are stored as HTML (produced by the web contentEditable editor).
// Agent responses are Markdown (from the LLM).
//
// Exports:
//   RichTextEditorController   — ObservableObject driving format-toolbar actions
//   RichTextEditorView         — UIViewRepresentable editor with real bold/italic/etc.
//   HTMLTextView               — UIViewRepresentable for read-only HTML note bodies
//   MarkdownBodyView           — SwiftUI view for agent Markdown messages

import SwiftUI
import UIKit
import Combine

// ── Base font & colors ─────────────────────────────────────────────────────────

private let kBodySize:   CGFloat = 16
private let kBodyFont    = UIFont(name: "Lora-Regular",    size: kBodySize) ?? UIFont.systemFont(ofSize: kBodySize)
private let kBoldFont    = UIFont(name: "Lora-Bold",       size: kBodySize) ?? UIFont.boldSystemFont(ofSize: kBodySize)
private let kItalicFont  = UIFont(name: "Lora-Italic",     size: kBodySize) ?? UIFont.italicSystemFont(ofSize: kBodySize)
private let kBoldItalic  = UIFont(name: "Lora-BoldItalic", size: kBodySize) ?? {
    let desc = UIFont.boldSystemFont(ofSize: kBodySize).fontDescriptor
    return UIFont(descriptor: desc.withSymbolicTraits(.traitItalic) ?? desc, size: kBodySize)
}()

private let kTextColor   = UIColor(red: 244/255, green: 228/255, blue: 193/255, alpha: 0.78)
private let kGold        = UIColor(red: 200/255, green: 134/255, blue:  26/255, alpha: 1.00)
private let kHighlight   = UIColor(red: 200/255, green: 134/255, blue:  26/255, alpha: 0.28)
private let kClearColor  = UIColor.clear

private var kBaseAttrs: [NSAttributedString.Key: Any] {
    [.font: kBodyFont, .foregroundColor: kTextColor]
}

// ── HTML ↔ NSAttributedString ─────────────────────────────────────────────────

/// Parse HTML (from the web note editor) into a themed NSAttributedString.
func htmlToAttributedString(_ html: String) -> NSAttributedString {
    guard !html.isEmpty else { return NSAttributedString() }

    // Inject a <style> block so the parsed HTML starts with theme-appropriate
    // base appearance before we overlay our own attributes below.
    let styled = """
    <html><head><meta charset="UTF-8">
    <style>
      body { font-family: "Lora", Georgia, serif; font-size: \(Int(kBodySize))px;
             color: rgba(244,228,193,0.78); background: transparent;
             line-height: 1.85; }
      b, strong { font-weight: bold; }
      i, em     { font-style: italic; }
      u         { text-decoration: underline; }
      mark      { background-color: rgba(200,134,26,0.28); }
    </style></head><body>\(html)</body></html>
    """

    guard let data = styled.data(using: .utf8),
          let attr = try? NSMutableAttributedString(
            data:    data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
          )
    else { return NSAttributedString(string: html, attributes: kBaseAttrs) }

    // Re-apply theme colours so the parsed HTML looks consistent on dark bg.
    let full = NSRange(location: 0, length: attr.length)
    attr.enumerateAttribute(.foregroundColor, in: full) { val, range, _ in
        // Only override the default black that NSAttributedString injects;
        // leave explicit author-chosen colours alone.
        if let c = val as? UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            let isBlack = r < 0.15 && g < 0.15 && b < 0.15
            if isBlack { attr.addAttribute(.foregroundColor, value: kTextColor, range: range) }
        } else {
            attr.addAttribute(.foregroundColor, value: kTextColor, range: range)
        }
    }

    return attr
}

/// Convert an NSAttributedString (from the iOS editor) to HTML for storage.
///
/// Uses a hand-rolled serializer rather than NSAttributedString's built-in HTML export.
/// The built-in export generates CSS-class-based HTML; when only the body fragment is
/// stored (without the accompanying <style> block) every formatting class becomes
/// meaningless, so bold/italic/highlight/color are all lost on re-open.
/// This serializer emits self-contained inline tags (<b>, <em>, <u>, <mark>) and
/// inline style attributes so the output round-trips correctly via htmlToAttributedString.
func attributedStringToHTML(_ attr: NSAttributedString) -> String {
    guard attr.length > 0 else { return "" }
    var html = ""

    attr.enumerateAttributes(
        in: NSRange(location: 0, length: attr.length),
        options: []
    ) { attrs, range, _ in
        var segment = (attr.string as NSString).substring(with: range)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")

        let font    = attrs[.font] as? UIFont ?? kBodyFont
        let isBold  = font.fontDescriptor.symbolicTraits.contains(.traitBold)
        let isItal  = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        let isUnder = (attrs[.underlineStyle] as? Int ?? 0) != 0

        var bgA: CGFloat = 0
        (attrs[.backgroundColor] as? UIColor ?? kClearColor)
            .getRed(nil, green: nil, blue: nil, alpha: &bgA)
        let isHL = bgA > 0.05

        var fgR: CGFloat = 244/255, fgG: CGFloat = 228/255, fgB: CGFloat = 193/255, fgA: CGFloat = 0.78
        if let c = attrs[.foregroundColor] as? UIColor { c.getRed(&fgR, green: &fgG, blue: &fgB, alpha: &fgA) }
        let isCustomColor = !(abs(fgR - 244/255) < 0.06 && abs(fgG - 228/255) < 0.06 && abs(fgB - 193/255) < 0.06)

        // Wrap innermost to outermost so nesting is valid.
        if isCustomColor { segment = "<span style=\"color:rgba(\(Int(fgR*255)),\(Int(fgG*255)),\(Int(fgB*255)),\(String(format: "%.2f", fgA)))\">\(segment)</span>" }
        if isHL          { segment = "<mark>\(segment)</mark>" }
        if isUnder       { segment = "<u>\(segment)</u>" }
        if isItal        { segment = "<em>\(segment)</em>" }
        if isBold        { segment = "<b>\(segment)</b>" }

        html += segment
    }

    // Strip trailing <br> tags introduced by a final newline in the attributed string.
    while html.hasSuffix("<br>") { html = String(html.dropLast(4)) }

    return html
}

// ── Rich-text editor controller ────────────────────────────────────────────────

/// ObservableObject shared between SwiftUI toolbar buttons and the UITextView.
/// The toolbar calls toggle*/apply* methods; the UIViewRepresentable holds the weak ref.
final class RichTextEditorController: ObservableObject {

    @Published var htmlOutput:    String = ""

    // Active-state flags — updated on every cursor move so the toolbar
    // can highlight the button that matches the current insertion format.
    @Published var isBold:         Bool = false
    @Published var isItalic:       Bool = false
    @Published var isUnderline:    Bool = false
    @Published var isHighlight:    Bool = false
    @Published var hasCustomColor: Bool = false

    weak var textView: UITextView?

    // HTML that arrived before the UITextView was in the hierarchy.
    // makeUIView reads this and applies it the moment the view is ready.
    fileprivate var pendingHTML: String = ""

    // ── Format actions ────────────────────────────────────────────────────────

    func toggleBold() {
        modifySelection { attr, range in
            let cur = attr[.font] as? UIFont ?? kBodyFont
            let isBold   = cur.fontDescriptor.symbolicTraits.contains(.traitBold)
            let isItalic = cur.fontDescriptor.symbolicTraits.contains(.traitItalic)
            let next: UIFont = isBold
                ? (isItalic ? kItalicFont   : kBodyFont)
                : (isItalic ? kBoldItalic   : kBoldFont)
            attr[.font] = next
        }
    }

    func toggleItalic() {
        modifySelection { attr, range in
            let cur = attr[.font] as? UIFont ?? kBodyFont
            let isBold   = cur.fontDescriptor.symbolicTraits.contains(.traitBold)
            let isItalic = cur.fontDescriptor.symbolicTraits.contains(.traitItalic)
            let next: UIFont = isItalic
                ? (isBold ? kBoldFont   : kBodyFont)
                : (isBold ? kBoldItalic : kItalicFont)
            attr[.font] = next
        }
    }

    func toggleUnderline() {
        modifySelection { attr, _ in
            let current = attr[.underlineStyle] as? Int ?? 0
            attr[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        }
    }

    func toggleHighlight() {
        modifySelection { attr, _ in
            let current = attr[.backgroundColor] as? UIColor ?? kClearColor
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            current.getRed(&r, green: &g, blue: &b, alpha: &a)
            let isHighlighted = a > 0.1
            attr[.backgroundColor] = isHighlighted ? kClearColor : kHighlight
        }
    }

    func applyTextColor(_ color: UIColor) {
        modifySelection { attr, _ in attr[.foregroundColor] = color }
    }

    func resetColor() {
        modifySelection { attr, _ in attr[.foregroundColor] = kTextColor }
    }

    // ── Content access ────────────────────────────────────────────────────────

    func setHTML(_ html: String) {
        // Always update htmlOutput immediately so the placeholder hides.
        htmlOutput = html
        if let tv = textView {
            tv.attributedText = htmlToAttributedString(html)
        } else {
            // UITextView not yet in the hierarchy — store for makeUIView to pick up.
            pendingHTML = html
        }
    }

    func currentHTML() -> String {
        guard let tv = textView else { return "" }
        return attributedStringToHTML(tv.attributedText)
    }

    // ── Format-state refresh ──────────────────────────────────────────────────

    /// Called on every cursor/selection change to keep the @Published flags
    /// in sync so the toolbar buttons light up when the cursor is inside
    /// formatted text.
    ///
    /// Rules (collapsed cursor):
    ///   • Prev char == '\n' AND (at end of text OR next char == '\n'):
    ///     truly empty line → reset typingAttributes + clear all flags.
    ///   • Prev char == '\n' AND next char is real text:
    ///     start of a non-empty paragraph → reflect that paragraph's first char.
    ///   • Position 0, text exists: reflect char 0.
    ///   • Normal: reflect the char to the left of the cursor.
    func refreshFormatState() {
        guard let tv = textView else { return }
        let sel  = tv.selectedRange
        let attr = tv.attributedText ?? NSAttributedString()
        let len  = attr.length

        // ── Selection (length > 0): inspect first selected char ───────────────
        if sel.length > 0 {
            let pos = min(sel.location, max(0, len - 1))
            if len > 0 { applyFormatState(attr.attributes(at: pos, effectiveRange: nil)) }
            else        { setAllInactive() }
            return
        }

        // ── Collapsed cursor ──────────────────────────────────────────────────
        let pos = sel.location

        guard len > 0 else { setAllInactive(); return }

        if pos == 0 {
            // Beginning of document — reflect char 0
            applyFormatState(attr.attributes(at: 0, effectiveRange: nil))
            return
        }

        // Character immediately to the left
        let prevChar = attr.attributedSubstring(
            from: NSRange(location: pos - 1, length: 1)
        ).string

        if prevChar == "\n" {
            if pos >= len {
                // At end of text after a newline → freshly created empty line
                tv.typingAttributes = kBaseAttrs
                setAllInactive()
            } else {
                let nextChar = attr.attributedSubstring(
                    from: NSRange(location: pos, length: 1)
                ).string
                if nextChar == "\n" {
                    // Between two newlines → blank line in the middle of text
                    tv.typingAttributes = kBaseAttrs
                    setAllInactive()
                } else {
                    // Cursor at the very start of a non-empty paragraph
                    applyFormatState(attr.attributes(at: pos, effectiveRange: nil))
                }
            }
            return
        }

        // Normal case: reflect the char to the left
        applyFormatState(attr.attributes(at: pos - 1, effectiveRange: nil))
    }

    private func setAllInactive() {
        isBold = false; isItalic = false
        isUnderline = false; isHighlight = false; hasCustomColor = false
    }

    private func applyFormatState(_ attrs: [NSAttributedString.Key: Any]) {
        let font    = attrs[.font] as? UIFont ?? kBodyFont
        let traits  = font.fontDescriptor.symbolicTraits
        let underln = attrs[.underlineStyle] as? Int ?? 0

        var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0, bgA: CGFloat = 0
        (attrs[.backgroundColor] as? UIColor ?? kClearColor)
            .getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)

        var fgR: CGFloat = 0, fgG: CGFloat = 0, fgB: CGFloat = 0
        (attrs[.foregroundColor] as? UIColor ?? kTextColor)
            .getRed(&fgR, green: &fgG, blue: &fgB, alpha: nil)
        // kTextColor ≈ (244/255, 228/255, 193/255)
        let isDefault = abs(fgR - 244/255) < 0.06
                     && abs(fgG - 228/255) < 0.06
                     && abs(fgB - 193/255) < 0.06

        isBold         = traits.contains(.traitBold)
        isItalic       = traits.contains(.traitItalic)
        isUnderline    = underln != 0
        isHighlight    = bgA > 0.05
        hasCustomColor = !isDefault
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// Apply `modifier` to selected text; if nothing selected, modify typing attrs.
    private func modifySelection(
        modifier: (inout [NSAttributedString.Key: Any], NSRange) -> Void
    ) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange

        if sel.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: tv.attributedText)
            // Walk sub-ranges so each span keeps its own existing attributes.
            mutable.enumerateAttributes(in: sel, options: []) { existing, subRange, _ in
                var attrs = existing
                modifier(&attrs, subRange)
                mutable.setAttributes(attrs, range: subRange)
            }
            // Preserve cursor / selection.
            tv.attributedText = mutable
            tv.selectedRange  = sel
        } else {
            var attrs = tv.typingAttributes
            modifier(&attrs, sel)
            tv.typingAttributes = attrs
        }

        htmlOutput = currentHTML()
        refreshFormatState()
    }
}

// ── UIViewRepresentable editor ─────────────────────────────────────────────────

struct RichTextEditorView: UIViewRepresentable {

    let controller: RichTextEditorController
    var placeholder: String = "Start writing…"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate           = context.coordinator
        tv.backgroundColor    = .clear
        tv.textColor          = kTextColor
        tv.tintColor          = kGold
        tv.font               = kBodyFont
        tv.isScrollEnabled    = false          // parent ScrollView handles scrolling
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.typingAttributes   = kBaseAttrs
        controller.textView   = tv
        // If setHTML was called before this view entered the hierarchy, apply it now.
        if !controller.pendingHTML.isEmpty {
            tv.attributedText     = htmlToAttributedString(controller.pendingHTML)
            controller.pendingHTML = ""
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Avoid resetting cursor position on every SwiftUI re-render.
        if context.coordinator.ignoreNextUpdate {
            context.coordinator.ignoreNextUpdate = false
            return
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, 220))
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditorView
        var ignoreNextUpdate = false

        init(_ parent: RichTextEditorView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            ignoreNextUpdate = true
            parent.controller.htmlOutput = parent.controller.currentHTML()
            parent.controller.refreshFormatState()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            parent.controller.refreshFormatState()
        }
    }
}

// ── Read-only HTML renderer ────────────────────────────────────────────────────

/// Renders an HTML note body (stored from the web editor) with full formatting.
struct HTMLTextView: UIViewRepresentable {

    let html: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable         = false
        tv.isSelectable       = true
        tv.backgroundColor    = .clear
        tv.isScrollEnabled    = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.attributedText     = htmlToAttributedString(html)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let attr = htmlToAttributedString(html)
        if tv.attributedText != attr {
            tv.attributedText = attr
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, 1))
    }
}

// ── Read-only note body (HTML → SwiftUI Text via AttributedString) ───────────
// Using Text(AttributedString) avoids UIViewRepresentable sizing issues entirely.

struct NoteHTMLView: View {
    let html: String
    @State private var content: AttributedString = AttributedString("")

    var body: some View {
        Text(content)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { content = buildAttributedString(html) }
            .onChange(of: html) { _, newHTML in content = buildAttributedString(newHTML) }
    }
}

private func buildAttributedString(_ html: String) -> AttributedString {
    guard !html.isEmpty else { return AttributedString(html) }

    let styled = """
    <html><head><meta charset="UTF-8">
    <style>
      body { font-family: "Lora", Georgia, serif; font-size: 19px;
             color: rgba(244,228,193,0.78); background: transparent; line-height: 1.9; }
      b, strong { font-weight: bold; }
      i, em     { font-style: italic; }
      u         { text-decoration: underline; }
      mark      { background-color: rgba(200,134,26,0.28); }
    </style></head><body>\(html)</body></html>
    """
    guard let data = styled.data(using: .utf8),
          let nsAttr = try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    else { return AttributedString(html) }

    // Remap HTML's default black text to the app's parchment colour.
    let full = NSRange(location: 0, length: nsAttr.length)
    nsAttr.enumerateAttribute(.foregroundColor, in: full) { val, range, _ in
        let needsRemap: Bool
        if let c = val as? UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            needsRemap = r < 0.15 && g < 0.15 && b < 0.15
        } else {
            needsRemap = true
        }
        if needsRemap { nsAttr.addAttribute(.foregroundColor, value: kTextColor, range: range) }
    }

    return (try? AttributedString(nsAttr, including: \.uiKit)) ?? AttributedString(nsAttr.string)
}

// ── Markdown renderer for agent messages ──────────────────────────────────────

/// Parses and renders agent Markdown.  Handles:
///   • inline bold (**text**), italic (*text*), inline code (`text`)
///   • ## headings,  > blockquote,  - / * / 1. lists,  --- horizontal rule
struct MarkdownBodyView: View {
    let text: String
    var isMine: Bool = false
    var baseFontSize: CGFloat = Theme.fontSM

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // ── Block rendering ───────────────────────────────────────────────────────

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .paragraph(let spans):
            inlineText(spans, size: baseFontSize, color: isMine ? Theme.parchment : Theme.parchment.opacity(0.90))
                .lineSpacing(5)

        case .heading(let level, let spans):
            let size: CGFloat = level == 1 ? baseFontSize + 4 : (level == 2 ? baseFontSize + 2 : baseFontSize + 1)
            inlineText(spans, size: size, color: Theme.parchment)
                .font(.playfair(size, weight: .semibold))
                .padding(.top, 4)

        case .bullet(let spans):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.lora(baseFontSize))
                    .foregroundColor(Theme.gold.opacity(0.65))
                inlineText(spans, size: baseFontSize, color: isMine ? Theme.parchment : Theme.parchment.opacity(0.90))
                    .lineSpacing(3)
            }

        case .ordered(let num, let spans):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(num).")
                    .font(.lora(baseFontSize))
                    .foregroundColor(Theme.gold.opacity(0.65))
                    .frame(minWidth: 18, alignment: .trailing)
                inlineText(spans, size: baseFontSize, color: isMine ? Theme.parchment : Theme.parchment.opacity(0.90))
                    .lineSpacing(3)
            }

        case .blockquote(let spans):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Theme.gold.opacity(0.35))
                    .frame(width: 2)
                inlineText(spans, size: baseFontSize, color: Theme.parchment.opacity(0.65))
                    .italic()
                    .lineSpacing(3)
            }

        case .code(let raw):
            Text(raw)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(Theme.gold.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.30))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.gold.opacity(0.15), lineWidth: 1))

        case .rule:
            Divider()
                .background(Theme.gold.opacity(0.18))
                .padding(.vertical, 2)
        }
    }

    // ── Inline span renderer ──────────────────────────────────────────────────

    private func inlineText(_ spans: [MDSpan], size: CGFloat, color: Color) -> some View {
        spans.reduce(Text("")) { acc, span in
            acc + spanText(span, size: size, color: color)
        }
    }

    private func spanText(_ span: MDSpan, size: CGFloat, color: Color) -> Text {
        switch span {
        case .plain(let s):
            return Text(s)
                .font(.lora(size))
                .foregroundColor(color)

        case .bold(let s):
            return Text(s)
                .font(.lora(size, weight: .bold))
                .foregroundColor(color)

        case .italic(let s):
            return Text(s)
                .font(.lora(size).italic())
                .foregroundColor(color)

        case .boldItalic(let s):
            return Text(s)
                .font(.lora(size, weight: .bold).italic())
                .foregroundColor(color)

        case .code(let s):
            return Text(s)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(Theme.gold)
        }
    }
}

// ── Markdown parser ────────────────────────────────────────────────────────────

private enum MDBlock {
    case paragraph([MDSpan])
    case heading(Int, [MDSpan])
    case bullet([MDSpan])
    case ordered(Int, [MDSpan])
    case blockquote([MDSpan])
    case code(String)
    case rule
}

private enum MDSpan {
    case plain(String)
    case bold(String)
    case italic(String)
    case boldItalic(String)
    case code(String)
}

private func parseBlocks(_ text: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var codeBuffer: [String] = []
    var inCode = false

    let lines = text.components(separatedBy: "\n")

    for line in lines {
        // Fenced code blocks
        if line.hasPrefix("```") {
            if inCode {
                blocks.append(.code(codeBuffer.joined(separator: "\n")))
                codeBuffer = []
                inCode = false
            } else {
                inCode = true
            }
            continue
        }
        if inCode { codeBuffer.append(line); continue }

        // Horizontal rule
        let stripped = line.trimmingCharacters(in: .whitespaces)
        if stripped == "---" || stripped == "***" || stripped == "___" {
            blocks.append(.rule); continue
        }

        // Headings
        if let m = line.firstMatch(of: /^(#{1,3})\s+(.+)$/) {
            let level = m.output.1.count
            blocks.append(.heading(level, parseInline(String(m.output.2))))
            continue
        }

        // Blockquote
        if line.hasPrefix("> ") || line.hasPrefix(">") {
            let content = String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1))
            blocks.append(.blockquote(parseInline(content)))
            continue
        }

        // Unordered list
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            let content = String(line.dropFirst(2))
            blocks.append(.bullet(parseInline(content)))
            continue
        }

        // Ordered list  "1. " "2. " etc.
        if let m = line.firstMatch(of: /^(\d+)\.\s+(.+)$/) {
            let num = Int(m.output.1) ?? 1
            blocks.append(.ordered(num, parseInline(String(m.output.2))))
            continue
        }

        // Empty line → paragraph break (skip blank paragraphs)
        if stripped.isEmpty { continue }

        // Default paragraph
        blocks.append(.paragraph(parseInline(line)))
    }

    if inCode && !codeBuffer.isEmpty {
        blocks.append(.code(codeBuffer.joined(separator: "\n")))
    }

    return blocks
}

/// Tokenise inline Markdown: ***bold italic***, **bold**, *italic*, `code`
private func parseInline(_ text: String) -> [MDSpan] {
    var spans: [MDSpan] = []
    var rest = text[text.startIndex...]

    while !rest.isEmpty {
        if let m = rest.firstMatch(of: /\*\*\*(.+?)\*\*\*/) {
            if m.range.lowerBound > rest.startIndex {
                spans.append(.plain(String(rest[rest.startIndex..<m.range.lowerBound])))
            }
            spans.append(.boldItalic(String(m.output.1)))
            rest = rest[m.range.upperBound...]
        } else if let m = rest.firstMatch(of: /\*\*(.+?)\*\*/) {
            if m.range.lowerBound > rest.startIndex {
                spans.append(.plain(String(rest[rest.startIndex..<m.range.lowerBound])))
            }
            spans.append(.bold(String(m.output.1)))
            rest = rest[m.range.upperBound...]
        } else if let m = rest.firstMatch(of: /\*(.+?)\*/) {
            if m.range.lowerBound > rest.startIndex {
                spans.append(.plain(String(rest[rest.startIndex..<m.range.lowerBound])))
            }
            spans.append(.italic(String(m.output.1)))
            rest = rest[m.range.upperBound...]
        } else if let m = rest.firstMatch(of: /`(.+?)`/) {
            if m.range.lowerBound > rest.startIndex {
                spans.append(.plain(String(rest[rest.startIndex..<m.range.lowerBound])))
            }
            spans.append(.code(String(m.output.1)))
            rest = rest[m.range.upperBound...]
        } else {
            spans.append(.plain(String(rest)))
            break
        }
    }

    return spans.isEmpty ? [.plain(text)] : spans
}
