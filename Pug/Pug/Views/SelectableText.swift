// SelectableText.swift
// Non-editable UITextView wrapper that supports long-press word selection and
// drag-handle range expansion inside a ScrollView — more reliable than
// SwiftUI Text + .textSelection(.enabled), which loses selection gestures to
// the scroll gesture recognizer.
//
// Markdown is rendered via Markdownosaur, which uses Apple's swift-markdown
// AST parser and produces a proper NSAttributedString with bold, italic,
// ordered/unordered lists, and paragraph spacing.

import SwiftUI
import Markdown
import Markdownosaur

struct SelectableText: UIViewRepresentable {
    let text: String

    init(_ text: String) { self.text = text }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false   // parent ScrollView handles scrolling
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard uiView.text != text else { return }
        var parser = Markdownosaur()
        let document = Document(parsing: text)
        let attributed = NSMutableAttributedString(attributedString: parser.attributedString(from: document))
        // Re-base all fonts to Dynamic Type body size, preserving bold/italic/monospace traits.
        let body = UIFont.preferredFont(forTextStyle: .body)
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.font, in: full) { value, range, _ in
            let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let descriptor = body.fontDescriptor.withSymbolicTraits(traits) ?? body.fontDescriptor
            attributed.addAttribute(.font, value: UIFont(descriptor: descriptor, size: body.pointSize), range: range)
        }
        // Apply system label color so text adapts to dark/light mode.
        attributed.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        uiView.attributedText = attributed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 390  // fallback; proposal.width is almost always set
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // Return the full proposed width so SwiftUI doesn't shrink-wrap the view
        // to the text's natural width, which causes it to appear half-width in an HStack.
        return CGSize(width: width, height: fitted.height)
    }
}
