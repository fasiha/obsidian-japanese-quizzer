// SelectableText.swift
// Non-editable UITextView wrapper that supports long-press word selection and
// drag-handle range expansion inside a ScrollView — more reliable than
// SwiftUI Text + .textSelection(.enabled), which loses selection gestures to
// the scroll gesture recognizer.

import SwiftUI

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
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 390  // fallback; proposal.width is almost always set
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // Return the full proposed width so SwiftUI doesn't shrink-wrap the view
        // to the text's natural width, which causes it to appear half-width in an HStack.
        return CGSize(width: width, height: fitted.height)
    }
}
