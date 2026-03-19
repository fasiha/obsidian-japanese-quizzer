// GrammarQuizView.swift
// Quiz UI for grammar items (tier 1 — always multiple choice).
// Parallel to QuizView for vocabulary; reuses the same visual helpers
// (score badge, chat thread, rescale sheet).

import AVFoundation
import SwiftUI

// MARK: - Speech helper

/// Wraps AVSpeechSynthesizer so the quiz view can toggle playback on/off
/// and know when playback ends naturally (to update the button state).
@Observable
final class GrammarAudioPlayer: NSObject, AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizer is not Sendable; we confine all access to the main
    // actor via DispatchQueue.main in the delegate callback, so opt out of the
    // compiler check with nonisolated(unsafe).
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()
    private(set) var isPlaying = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Plays `sentences` one after another (0.8 s gap between them) using the given BCP-47 language tag.
    func play(sentences: [String], language: String) {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = true
        for (index, text) in sentences.enumerated() {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
            if index < sentences.count - 1 {
                utterance.postUtteranceDelay = 0.8
            }
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
    }

    /// Tap 1 → play; tap 2 → stop; tap 3 → play again.
    func toggle(sentences: [String], language: String) {
        if isPlaying { stop() } else { play(sentences: sentences, language: language) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.isPlaying = false
        }
    }
}

struct GrammarQuizView: View {
    @State var session: GrammarAppSession
    let manifest: GrammarManifest
    @State private var showRescaleSheet = false
    @State private var vocabExpanded = false
    @State private var audioPlayer = GrammarAudioPlayer()

    var body: some View {
        Group {
            switch session.phase {
            case .idle, .loadingItems, .generating:
                loadingView
            case .awaitingTap(let question):
                awaitingTapView(question: question)
            case .chatting:
                chattingView
            case .noItems:
                noItemsView
            case .finished:
                finishedView
            case .error(let msg):
                errorView(msg)
            }
        }
        .navigationTitle("Grammar Quiz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if session.canStartNewSession {
                    Button("New Session") { session.refreshSession(manifest: manifest) }
                }
            }
        }
        .onChange(of: session.currentItem?.topicId) { vocabExpanded = false }
        .onChange(of: session.phase) { audioPlayer.stop() }
        .onDisappear { audioPlayer.stop() }
        .sheet(isPresented: $showRescaleSheet) {
            RescaleSheet(
                currentHalflife: session.gradedHalflife ?? 24,
                reviewCount: session.gradedReviewCount
            ) { hours in
                Task { await session.rescaleCurrentFacet(hours: hours) }
            }
        }
        .task {
            if case .idle = session.phase { session.start(manifest: manifest) }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(session.phase == .generating ? "Generating question…" : "Loading grammar items…")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Awaiting tap

    private func awaitingTapView(question: GrammarMultipleChoiceQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                progressAndFacet

                // Stem (English context for production; Japanese sentence for recognition)
                stemView(question: question)

                // Collapsible vocabulary hints — disabled while fetch is in progress
                assumedVocabDisclosure

                // Choice buttons — show a cloze template header when the choices share
                // a meaningful common prefix and suffix (typically production-facet questions).
                let letters = ["A", "B", "C", "D"]
                let cloze = question.choiceClozeTemplate()
                let hasCloze = !cloze.prefix.isEmpty || !cloze.suffix.isEmpty
                let glosses = session.assumedVocab  // nil while loading
                VStack(spacing: 10) {
                    if hasCloze {
                        // Template header: "prefix ___ suffix" — annotate with furigana when ready.
                        let template = "\(cloze.prefix)\(grammarGapToken)\(cloze.suffix)"
                        if let gs = glosses, !gs.isEmpty {
                            SentenceFuriganaView(sentence: template, glosses: gs)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        } else {
                            Text(template)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }
                    ForEach(0..<question.choices.count, id: \.self) { i in
                        Button { session.tapChoice(i) } label: {
                            HStack(spacing: 12) {
                                Text(letters[safe: i] ?? "?")
                                    .font(.headline)
                                    .frame(width: 28, height: 28)
                                    .background(.tint.opacity(0.15), in: Circle())
                                    .foregroundStyle(.tint)
                                // When there is a cloze template, show only the unique core
                                // with … on whichever sides were trimmed; otherwise full text.
                                let core = hasCloze ? cloze.cores[safe: i] ?? question.choiceDisplay(i) : nil
                                let coreDisplay = core.map {
                                    "\(cloze.prefix.isEmpty ? "" : "…")\($0)\(cloze.suffix.isEmpty ? "" : "…")"
                                }
                                let labelText = coreDisplay ?? question.choiceDisplay(i)
                                if let gs = glosses, !gs.isEmpty {
                                    SentenceFuriganaView(sentence: labelText, glosses: gs)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(labelText)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Audio playback button — plays Japanese sentences aloud.
                // Production: choice A gets the full sentence; choices B-D get
                // just the differing core with a small kanji-safe context window
                // from the shared prefix/suffix so the listener hears each choice
                // in minimal grammatical context without repeating the full frame.
                // Recognition: the Japanese stem only.
                let japaneseSentences: [String] = {
                    if session.currentItem?.facet == "recognition" {
                        return [question.stem]
                    } else {
                        return audioSentences(for: question, cloze: cloze)
                    }
                }()
                Button {
                    audioPlayer.toggle(sentences: japaneseSentences, language: "ja-JP")
                } label: {
                    Label(audioPlayer.isPlaying ? "Stop audio" : "Play audio",
                          systemImage: audioPlayer.isPlaying ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .tint(audioPlayer.isPlaying ? .secondary : .blue)
                .frame(maxWidth: .infinity)

                // Uncertainty row
                HStack(spacing: 8) {
                    Button("Don't know?") {
                        session.uncertaintyUnlocked = !session.uncertaintyUnlocked
                    }
                    .buttonStyle(.bordered)
                    .tint(session.uncertaintyUnlocked ? .secondary : .orange)

                    Button("No idea") { session.tapUncertain(score: 0.0) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(!session.uncertaintyUnlocked)

                    Button("Inkling") { session.tapUncertain(score: 0.25) }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(!session.uncertaintyUnlocked)
                }
                .frame(maxWidth: .infinity)

                Button("Skip →") { session.nextQuestion() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    /// Displays the question stem and, for production questions, the gapped sentence below it.
    /// When the vocab-assumed pass has completed and found readings, annotates the Japanese
    /// text with furigana above identified words.
    private func stemView(question: GrammarMultipleChoiceQuestion) -> some View {
        let glosses = session.assumedVocab  // nil while loading, non-nil when ready
        let facet = session.currentItem?.facet
        return VStack(alignment: .leading, spacing: 8) {
            // Recognition stem is Japanese — annotate with furigana when vocab is ready.
            // Production stem is English — always plain.
            if facet == "recognition", let gs = glosses, !gs.isEmpty {
                SentenceFuriganaView(sentence: question.stem, glosses: gs)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10))
            } else {
                SelectableText(question.stem)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10))
            }

            // Production: gapped Japanese sentence — annotate with furigana when vocab is ready.
            if facet == "production",
               let gapped = question.displayGappedSentence, !gapped.isEmpty {
                if let gs = glosses, !gs.isEmpty {
                    SentenceFuriganaView(sentence: gapped, glosses: gs)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(.separator), lineWidth: 0.5)
                        )
                } else {
                    SelectableText(gapped)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(.separator), lineWidth: 0.5)
                        )
                }
            }
        }
    }

    // MARK: - Assumed vocab disclosure

    private var assumedVocabDisclosure: some View {
        let ready = session.assumedVocab != nil
        let empty = session.assumedVocab?.isEmpty == true
        return DisclosureGroup(isExpanded: $vocabExpanded) {
            if let glosses = session.assumedVocab, !glosses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(glosses, id: \.word) { gloss in
                        HStack(alignment: .top, spacing: 8) {
                            // Show furigana-annotated word when ruby segments are available,
                            // otherwise fall back to plain word text.
                            if let segs = gloss.rubySegments, segs.contains(where: { $0.rt != nil }) {
                                HStack(spacing: 0) {
                                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                                        if let rt = seg.rt {
                                            VStack(spacing: 0) {
                                                Text(rt).font(.system(size: 9)).foregroundStyle(.secondary)
                                                Text(seg.ruby).font(.body)
                                            }
                                        } else {
                                            Text(seg.ruby).font(.body)
                                                .padding(.top, 13) // align baseline with annotated segments
                                        }
                                    }
                                }
                            } else {
                                Text(gloss.word).font(.body)
                            }
                            Text(gloss.gloss)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            Text(empty ? "Vocabulary (none)" : "Vocabulary")
                .font(.subheadline)
                .foregroundStyle(ready ? .primary : .tertiary)
        }
        .disabled(!ready || empty)
    }

    // MARK: - Chatting

    private var chattingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                progressAndFacet

                // Chat thread
                ForEach(Array(session.chatMessages.enumerated()), id: \.offset) { _, msg in
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

                // Score badge + optional "Tutor me" button for wrong multiple-choice answers
                if let score = session.gradedScore {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            scoreIndicator(score)
                            Text(scoreLabel(score))
                                .font(.headline)
                        }
                        if session.canStartTutorSession {
                            Spacer()
                            Button("Tutor me") { session.startTutorSession() }
                                .buttonStyle(.bordered)
                                .tint(.blue)
                        }
                    }
                    .padding(.top, session.chatMessages.isEmpty ? 40 : 4)
                }

                // Chat input
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        session.gradedScore == nil ? "Answer or ask anything…" : "Ask a follow-up… (optional)",
                        text: $session.chatInput,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(session.isSendingChat)

                    if session.isSendingChat {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.bottom, 6)
                    } else {
                        Button {
                            session.sendChatMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(session.chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.bottom, 2)
                    }
                }

                // Advance buttons
                let isLast = session.currentIndex + 1 >= session.items.count
                let isGraded = session.gradedScore != nil
                if isGraded {
                    HStack {
                        Button("Adjust…") { showRescaleSheet = true }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button(isLast ? "Finish" : "Next Question →") { session.nextQuestion() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Skip →") { session.nextQuestion() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
    }

    // MARK: - End states

    private var noItemsView: some View {
        ContentUnavailableView(
            "No grammar topics to quiz",
            systemImage: "text.book.closed",
            description: Text("Enroll some grammar topics in the Grammar browser first.")
        )
    }

    private var finishedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Session complete!")
                .font(.title2.bold())
            Button("Start another session") { session.start(manifest: manifest) }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { session.start(manifest: manifest) }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Shared helpers

    private var progressAndFacet: some View {
        HStack {
            Text(session.progress)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let item = session.currentItem {
                facetBadge(item.facet)
            }
        }
    }

    private func facetBadge(_ facet: String) -> some View {
        Text(facet)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }

    private func scoreIndicator(_ score: Double) -> some View {
        Circle()
            .fill(scoreColor(score))
            .frame(width: 16, height: 16)
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 0.8...: return .green
        case 0.5...: return .orange
        default:     return .red
        }
    }

    private func scoreLabel(_ score: Double) -> String {
        switch score {
        case 0.9...: return "Excellent"
        case 0.75...: return "Good"
        case 0.5...: return "Partial"
        default:     return "Incorrect"
        }
    }
}

// Reuse the safe subscript already defined in GrammarAppSession via a local extension here.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Audio sentence helpers

/// Builds the list of Japanese strings to speak for a production-facet question.
/// Choice A speaks the full sentence so the listener hears the complete frame once.
/// Choices B-D speak only the differing core with a small kanji-safe context window
/// taken from the shared prefix/suffix, avoiding bisecting a kanji compound.
private func audioSentences(
    for question: GrammarMultipleChoiceQuestion,
    cloze: (prefix: String, suffix: String, cores: [String])
) -> [String] {
    let hasCloze = !cloze.prefix.isEmpty || !cloze.suffix.isEmpty
    return question.choices.indices.map { i in
        let full = question.choices[i].joined(separator: ", ")
        guard hasCloze, i > 0, let core = cloze.cores[safe: i] else { return full }
        let prefixCtx = kanjiSafeTail(of: cloze.prefix, maxChars: 5)
        let suffixCtx = kanjiSafeHead(of: cloze.suffix, maxChars: 5)
        return prefixCtx + core + suffixCtx
    }
}

/// Returns the trailing context of `s` (up to `maxChars` characters), extended
/// backward if the cut point falls inside a kanji compound (consecutive CJK characters).
/// Caps total expansion at 2 × maxChars to avoid pulling in large runs.
private func kanjiSafeTail(of s: String, maxChars: Int) -> String {
    let chars = Array(s)
    guard !chars.isEmpty else { return "" }
    var start = max(0, chars.count - maxChars)
    // If both the character at `start` and the one just before it are CJK,
    // we landed mid-compound — walk backward to exit the kanji run.
    let cap = max(0, chars.count - maxChars * 2)
    while start > cap && start > 0 && chars[start].isCJK && chars[start - 1].isCJK {
        start -= 1
    }
    return String(chars[start...])
}

/// Returns the leading context of `s` (up to `maxChars` characters), extended
/// forward if the cut point falls inside a kanji compound.
private func kanjiSafeHead(of s: String, maxChars: Int) -> String {
    let chars = Array(s)
    guard !chars.isEmpty else { return "" }
    var end = min(chars.count, maxChars)
    let cap = min(chars.count, maxChars * 2)
    while end < cap && end < chars.count && chars[end - 1].isCJK && chars[end].isCJK {
        end += 1
    }
    return String(chars[..<end])
}

private extension Character {
    /// True for characters in the CJK Unified Ideographs block (common kanji range).
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)   // CJK Extension A
            || (0xF900...0xFAFF).contains(scalar.value)   // CJK Compatibility
    }
}
