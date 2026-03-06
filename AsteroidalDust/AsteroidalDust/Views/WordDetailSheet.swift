// WordDetailSheet.swift
// Unified word detail / learning-commitment sheet.
//
// Shown in two situations:
//   1. Tapping any row in VocabBrowserView (detail mode)
//   2. Swiping "Learn" on a not-yet-learned word (also detail mode — same view)
//
// The word-info section (kanji forms, readings, meanings) is always visible and scrollable.
// The action section varies by the word's current status.
// A Claude chat section at the bottom lets the user explore the word before committing.
//
// Future additions for learning words: review history (reviews.notes).

import SwiftUI
import GRDB

struct WordDetailSheet: View {
    let item: VocabItem
    let corpus: VocabCorpus
    let db: QuizDB
    let session: QuizSession    // for AnthropicClient + ToolHandler access

    @Environment(\.dismiss) private var dismiss
    @State private var kanjiOkChoice: Bool = false
    @State private var isWorking = false
    @State private var explore: WordExploreSession? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    wordInfoSection
                    Divider()
                    actionsSection
                    Divider()
                    exploreChatSection
                }
                .padding()
            }
            .navigationTitle(item.wordText)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .disabled(isWorking)
            .overlay {
                if isWorking { ProgressView() }
            }
            .onAppear {
                explore = WordExploreSession(
                    client: session.client,
                    toolHandler: session.toolHandler,
                    item: item,
                    corpus: corpus
                )
            }
        }
    }

    // MARK: - Word info (always visible)

    private var wordInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !item.writtenTexts.isEmpty {
                infoGroup(heading: "Written forms") {
                    ForEach(item.writtenTexts, id: \.self) { form in
                        Text(form).font(.title2)
                    }
                }
            }

            infoGroup(heading: "Readings") {
                ForEach(item.kanaTexts, id: \.self) { kana in
                    Text(kana).font(.title3)
                }
            }

            infoGroup(heading: "Meanings") {
                ForEach(Array(item.meanings.enumerated()), id: \.offset) { _, meaning in
                    Text("• \(meaning)")
                }
            }

            if !item.sources.isEmpty {
                infoGroup(heading: "Appears in") {
                    Text(item.sources.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)  // propagates to all Text descendants
    }

    @ViewBuilder
    private func infoGroup<Content: View>(heading: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    // MARK: - Actions (vary by status)

    @ViewBuilder
    private var actionsSection: some View {
        switch item.status {
        case .notYetLearned:
            notYetLearnedActions
        case .learning:
            learningActions
        case .known:
            knownActions
        }
    }

    // Not yet learned: kanji question + learn button, or just "I know this"
    private var notYetLearnedActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !item.writtenTexts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Will you memorize the written form?")
                        .font(.headline)
                    Text("Adds kanji-reading and kanji-writing practice to your quiz sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Kanji commitment", selection: $kanjiOkChoice) {
                        Text("Reading only").tag(false)
                        Text("Yes, including kanji").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }

            Button {
                commit()
            } label: {
                Label("Start learning this word", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button {
                markKnown()
            } label: {
                Label("I already know this word", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
        }
    }

    // Learning: toggle kanji, stop learning, mark known
    private var learningActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !item.writtenTexts.isEmpty {
                Button {
                    toggleKanji()
                } label: {
                    Label(
                        item.kanjiOk ? "Remove kanji practice" : "Add kanji practice",
                        systemImage: item.kanjiOk ? "minus.circle" : "plus.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(item.kanjiOk ? .orange : .indigo)
            }

            Button(role: .destructive) {
                stopLearning()
            } label: {
                Label("Stop learning this word", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                markKnown()
            } label: {
                Label("I already know this word", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
        }
    }

    // Known: just undo
    private var knownActions: some View {
        Button {
            undoKnown()
        } label: {
            Label("Move back to \"Not yet learned\"", systemImage: "arrow.uturn.backward")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }

    // MARK: - Claude explore chat

    private var exploreChatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Claude")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            if let explore {
                // Chat bubbles
                ForEach(Array(explore.messages.enumerated()), id: \.offset) { _, msg in
                    HStack(alignment: .top) {
                        if msg.isUser { Spacer(minLength: 40) }
                        SelectableText(msg.text)
                            .padding(10)
                            .background(
                                msg.isUser
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        if !msg.isUser { Spacer(minLength: 40) }
                    }
                }

                // Input row
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask about readings, kanji, mnemonics…",
                              text: Binding(
                                get: { explore.input },
                                set: { explore.input = $0 }
                              ),
                              axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(explore.isSending)

                    if explore.isSending {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.bottom, 6)
                    } else {
                        Button {
                            explore.send()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(explore.input.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.bottom, 2)
                    }
                }
            }
        }
    }

    // MARK: - Action implementations

    private func commit() {
        let ok = item.writtenTexts.isEmpty ? false : kanjiOkChoice
        isWorking = true
        Task {
            await corpus.startLearning(wordId: item.id, kanjiOk: ok, db: db)
            isWorking = false
            dismiss()
        }
    }

    private func stopLearning() {
        isWorking = true
        Task {
            await corpus.stopLearning(wordId: item.id, db: db)
            isWorking = false
            dismiss()
        }
    }

    private func markKnown() {
        isWorking = true
        Task {
            await corpus.markKnown(wordId: item.id, db: db)
            isWorking = false
            dismiss()
        }
    }

    private func toggleKanji() {
        isWorking = true
        Task {
            await corpus.toggleKanji(wordId: item.id, db: db)
            isWorking = false
        }
    }

    private func undoKnown() {
        isWorking = true
        Task {
            await corpus.undoKnown(wordId: item.id, db: db)
            isWorking = false
            dismiss()
        }
    }
}

// MARK: - SelectableText (local copy — same as QuizView's)

private struct SelectableText: UIViewRepresentable {
    let text: String

    init(_ text: String) { self.text = text }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
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
        let width = proposal.width ?? 390
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
