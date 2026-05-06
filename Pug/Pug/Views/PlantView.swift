// PlantView.swift
// UI for the "Learn" (planting) flow.
//
// Phase mapping:
//   idle / loading  → spinner
//   introducing     → IntroduceCardView (word heading, senses, kanji toggle, action buttons)
//   awaitingTap     → app-side multiple-choice drill
//   tapFeedback     → correct/incorrect result with "Continue" button
//   allDone         → completion screen
//   noNewWords      → "all caught up" screen
//   error           → error screen
//
// The view is presented as a sheet from VocabBrowserView.

import SwiftUI
import GRDB

struct PlantView: View {
    @Bindable var session: PlantingSession
    let jmdict: any DatabaseReader
    let client: AnthropicClient
    let toolHandler: ToolHandler

    @State private var selectedWordForDetail: VocabItemSelection? = nil

    // Chat state for the post-drill feedback view. Reset each time a new tapFeedback phase begins.
    @State private var postDrillChatMessages: [(isUser: Bool, text: String)] = []
    @State private var postDrillChatInput: String = ""
    @State private var postDrillIsSending: Bool = false
    @State private var postDrillConversation: [AnthropicMessage] = []

    // The last path component of the document title, used as the navigation title.
    private var shortTitle: String {
        session.documentTitle.components(separatedBy: "/").last ?? session.documentTitle
    }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle, .loading:
                    loadingView
                case .introducing:
                    if let word = session.currentIntroWord {
                        introduceCardView(word: word)
                    } else {
                        loadingView
                    }
                case .awaitingTap(let mc):
                    drillView(mc: mc)
                case .tapFeedback(let correct, let explanation):
                    postDrillChattingView(correct: correct, explanation: explanation)
                case .batchDone:
                    batchDoneView
                case .allDone:
                    allDoneView
                case .noNewWords:
                    noNewWordsView
                case .error(let msg):
                    errorView(msg)
                }
            }
            .navigationTitle("Learn: \(shortTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) { ProblemReportBanner(report: $session.pendingReport) }
            .onChange(of: session.phase) { _, newPhase in
                if case .tapFeedback(let correct, _) = newPhase, let mc = session.lastAnsweredMC {
                    seedPostDrillChat(mc: mc, choiceIndex: session.lastAnswerChoiceIndex, correct: correct)
                }
            }
            .sheet(item: $selectedWordForDetail) { selection in
                WordDetailSheet(
                    initialItem: selection.item,
                    db: session.db,
                    client: client,
                    toolHandler: toolHandler,
                    jmdict: jmdict,
                    origin: selection.origin
                )
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Introduce card

    private func introduceCardView(word: VocabItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Progress indicator
                let planted = session.totalToPlant - session.remainingWords.count
                let current = planted + session.batchIntroducedCount + 1
                Text("Word \(current) of \(session.totalToPlant)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Word heading
                VStack(alignment: .leading, spacing: 6) {
                    let displayKana = word.commitment?.committedReading ?? word.kanaTexts.first
                    Text(word.wordText)
                        .font(.largeTitle)
                        .bold()
                    if let kana = displayKana, kana != word.wordText {
                        Text(kana)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Document-scoped senses
                let docSenses = documentScopedSenses(word: word)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(docSenses.enumerated()), id: \.offset) { _, sense in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sense.glosses.joined(separator: "; "))
                                if !sense.partOfSpeech.isEmpty {
                                    Text(sense.partOfSpeech.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                // Sentences from this document that use the word
                let docRefs = word.references[session.documentTitle] ?? []
                let contexts = docRefs.compactMap(\.context)
                if !contexts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In this document")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        ForEach(contexts.indices, id: \.self) { i in
                            SentenceFuriganaView(htmlRuby: stripUnsupportedHtmlTags(contexts[i]))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Divider()

                // Kanji info cards (only when the word has real kanji forms).
                // Tap a card to enroll that kanji; deselect all to skip kanji learning.
                if !word.writtenTexts.isEmpty && !word.isKanaOnly {
                    kanjiCharPicker(for: word)
                }

                Divider()

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        selectedWordForDetail = VocabItemSelection(
                            item: word,
                            origin: .document(title: session.documentTitle)
                        )
                    } label: {
                        Text("Details")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Skip") { session.tapSkip() }
                        .buttonStyle(.bordered)
                        .tint(.secondary)

                    Button("Known") { session.tapKnown() }
                        .buttonStyle(.bordered)
                        .tint(.green)

                    Button("Got it  →") { session.tapGotIt() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    // MARK: - Drill (app-side multiple choice)
    //
    // Visual grammar mirrors QuizView.awaitingTapView (QuizView.swift).
    // Differences that are intentional:
    //   • No uncertainty buttons ("Don't know? / No idea / Inkling") — during planting
    //     the user is still learning, so there is no SRS halflife to hedge against.
    //   • No "Skip →" button — skipping happens on the introduce card, not the drill.
    //   • Progress counter shows "N of M introduced" rather than the SRS queue fraction.

    private func drillView(mc: PlantingMultipleChoice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Facet badge + progress
                HStack {
                    let planted = session.totalToPlant - session.remainingWords.count
                    let current = planted + session.batchIntroducedCount
                    Text("\(current) of \(session.totalToPlant) introduced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    facetBadge(mc.item.facet)
                }

                // Question stem — boxed background matches QuizView.awaitingTapView.
                Text(mc.stem)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                // Choice buttons — letter badge style matches QuizView.awaitingTapView.
                let letters = ["A", "B", "C", "D"]
                VStack(spacing: 10) {
                    ForEach(Array(mc.choices.enumerated()), id: \.offset) { i, choice in
                        Button {
                            session.tapChoice(i)
                        } label: {
                            HStack(spacing: 12) {
                                Text(letters[i])
                                    .font(.headline)
                                    .frame(width: 28, height: 28)
                                    .background(.tint.opacity(0.15), in: Circle())
                                    .foregroundStyle(.tint)
                                Text(choice)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Post-drill chat

    private func postDrillChattingView(correct: Bool, explanation: String) -> some View {
        let mc = session.lastAnsweredMC
        let planted = session.totalToPlant - session.remainingWords.count
        let introduced = planted + session.batchIntroducedCount
        let progressLabel = "\(introduced) of \(session.totalToPlant) introduced"
        let tutorAction: (() -> Void)? = (!correct && postDrillChatMessages.count <= 2 && !postDrillIsSending)
            ? { sendPostDrillMessage("I got this wrong. Please explain the correct answer and what I may have been confusing it with.") }
            : nil
        return PostAnswerChatView(
            messages: postDrillChatMessages,
            chatInput: $postDrillChatInput,
            isSending: postDrillIsSending,
            gradedScore: correct ? 1.0 : 0.0,
            facet: mc?.item.facet ?? "",
            progressLabel: progressLabel,
            advanceLabel: "Continue  →",
            onSend: sendPostDrillChat,
            onAdvance: session.continueAfterFeedback,
            onShowDetails: {
                guard let mc = session.lastAnsweredMC,
                      let word = session.documentWords.first(where: { $0.id == mc.item.wordId })
                else { return }
                selectedWordForDetail = VocabItemSelection(item: word,
                                                           origin: .document(title: session.documentTitle))
            },
            tutorMeAction: tutorAction,
            onReportProblem: { session.reportProblem() }
        )
    }

    private func seedPostDrillChat(mc: PlantingMultipleChoice, choiceIndex: Int, correct: Bool) {
        let letters = ["A", "B", "C", "D"]
        let choicesText = mc.choices.enumerated().map { "\(letters[$0])) \($1)" }.joined(separator: "\n")
        let questionBubble = "\(mc.stem)\n\n\(choicesText)"
        let chosenLetter = letters[choiceIndex]
        let correctLetter = letters[mc.correctIndex]
        let answerBubble = correct
            ? "✓ \(chosenLetter)) \(mc.choices[choiceIndex])"
            : "✗ Wrong: \(chosenLetter)) \(mc.choices[choiceIndex])\n✓ Correct: \(correctLetter)) \(mc.choices[mc.correctIndex])"
        postDrillChatMessages = [
            (isUser: false, text: questionBubble),
            (isUser: true, text: answerBubble)
        ]
        postDrillChatInput = ""
        postDrillIsSending = false
        postDrillConversation = []
    }

    private func sendPostDrillChat() {
        let text = postDrillChatInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        sendPostDrillMessage(text)
        postDrillChatInput = ""
    }

    private func sendPostDrillMessage(_ text: String) {
        guard !postDrillIsSending, let mc = session.lastAnsweredMC else { return }
        postDrillIsSending = true
        postDrillConversation.append(AnthropicMessage(role: "user", content: [.text(text)]))
        postDrillChatMessages.append((isUser: true, text: text))
        let systemPromptText = postDrillSystemPrompt(mc: mc)
        let conversation = postDrillConversation
        Task {
            do {
                let (response, updatedMsgs, _) = try await client.send(
                    messages: conversation,
                    system: systemPromptText,
                    maxTokens: 1024,
                    chatContext: .vocabQuiz(wordId: mc.item.wordId, facet: mc.item.facet,
                                            sessionId: "planting-\(mc.item.wordId)"),
                    templateId: nil
                )
                postDrillConversation = updatedMsgs
                let displayText = response.trimmingCharacters(in: .whitespacesAndNewlines)
                if !displayText.isEmpty {
                    postDrillChatMessages.append((isUser: false, text: displayText))
                }
            } catch {
                postDrillChatMessages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
            }
            postDrillIsSending = false
        }
    }

    private func postDrillSystemPrompt(mc: PlantingMultipleChoice) -> String {
        let letters = ["A", "B", "C", "D"]
        let choicesText = mc.choices.enumerated().map { "\(letters[$0])) \($1)" }.joined(separator: "\n")
        let chosenLetter = letters[session.lastAnswerChoiceIndex]
        let correctLetter = letters[mc.correctIndex]
        let wasCorrect = session.lastAnswerChoiceIndex == mc.correctIndex
        return """
        You are a Japanese language tutor. The student is learning new vocabulary via a first-time introduction and drill (planting).

        Current drill question:
        \(mc.stem)

        \(choicesText)

        Student chose: \(chosenLetter)) \(mc.choices[session.lastAnswerChoiceIndex]) — \(wasCorrect ? "Correct ✓" : "Incorrect ✗")
        Correct answer: \(correctLetter)) \(mc.choices[mc.correctIndex])

        Help the student understand the word, why their answer was \(wasCorrect ? "correct" : "wrong"), and any relevant nuance. Be concise.
        """
    }

    // MARK: - Done screens

    @Environment(\.dismiss) private var dismiss
    @Environment(VocabCorpus.self) private var corpus

    private var batchDoneView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Batch planted!")
                        .font(.title2.bold())
                    Text("\(session.completedBatchWords.count) word\(session.completedBatchWords.count == 1 ? "" : "s") added to your review queue.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Words planted")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    ForEach(session.completedBatchWords) { word in
                        let kana = word.commitment?.committedReading ?? session.documentResolvedForms(for: word)?.kana ?? word.kanaTexts.first
                        HStack(spacing: 12) {
                            Text(word.wordText)
                                .font(.title3)
                                .bold()
                            if let kana, kana != word.wordText {
                                Text(kana)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let gloss = word.senseExtras.first?.glosses.first {
                                Text(gloss)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Divider()

                let remaining = session.remainingWords.count
                Text("\(remaining) word\(remaining == 1 ? "" : "s") still to plant in this document. Tap Learn again when you're ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    private var allDoneView: some View {
        ContentUnavailableView {
            Label("All words planted!", systemImage: "leaf.fill")
        } description: {
            Text("All \(session.totalToPlant) words from \"\(shortTitle)\" are now in your SRS review queue.")
        }
    }

    private var noNewWordsView: some View {
        ContentUnavailableView {
            Label("All caught up!", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Every word in \"\(shortTitle)\" is already in your learning queue.")
        }
    }

    private func errorView(_ msg: String) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(msg)
        }
    }

    // MARK: - Helpers

    /// Senses relevant to this document: union of LLM-inferred sense indices across all
    /// references for the current document title.  Falls back to the first three senses.
    private func documentScopedSenses(word: VocabItem) -> [SenseExtra] {
        let refs = word.references[session.documentTitle] ?? []
        let indices = Array(Set(refs.compactMap(\.llmSense).flatMap(\.senseIndices))).sorted()
        if indices.isEmpty {
            return Array(word.senseExtras.prefix(3))
        }
        return indices.compactMap { i in i < word.senseExtras.count ? word.senseExtras[i] : nil }
    }

    /// All individual kanji characters found in the first written form of a word.
    private func introKanjiChars(for word: VocabItem) -> [String] {
        guard let firstForm = word.writtenForms.flatMap(\.forms).first else { return [] }
        return firstForm.furigana.extractKanji()
    }

    /// Tappable kanji info cards for the intro (planting) flow.
    @ViewBuilder
    private func kanjiCharPicker(for word: VocabItem) -> some View {
        let firstFormSegments = word.writtenForms.flatMap(\.forms).first?.furigana ?? []
        let allKanji = introKanjiChars(for: word)
        if !allKanji.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kanji to learn")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                ForEach(allKanji, id: \.self) { kanji in
                    let enrolled = session.currentIntroSelectedKanji.contains(kanji)
                    KanjiInfoCard(
                        kanji: kanji,
                        wordReading: readingForKanji(kanji, in: firstFormSegments),
                        activeWordMeanings: word.kanjiMeanings?[kanji] ?? [],
                        kanjidicDB: toolHandler.kanjidic,
                        isWordEnrolled: enrolled,
                        isKanjiEnrolled: false,
                        otherWords: corpus.otherEnrolledWords(for: kanji, excluding: word.id),
                        onToggleWord: {
                            var chars = session.currentIntroSelectedKanji
                            if chars.contains(kanji) { chars.remove(kanji) } else { chars.insert(kanji) }
                            session.currentIntroSelectedKanji = chars
                        },
                        onToggleKanji: {},
                        onTapOtherWord: { other in
                            selectedWordForDetail = VocabItemSelection(item: other, origin: nil)
                        }
                    )
                }
            }
        }
    }

    /// Capsule badge showing the facet name — matches facetBadge in QuizView.swift.
    private func facetBadge(_ facet: String) -> some View {
        Text(facet.replacingOccurrences(of: "-", with: " "))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}
