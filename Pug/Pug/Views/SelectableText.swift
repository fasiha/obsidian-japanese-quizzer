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
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
