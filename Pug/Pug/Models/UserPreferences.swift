// UserPreferences.swift
// Per-device user preferences, backed by UserDefaults.

import Foundation
import Observation

enum QuizStyle: String, CaseIterable, Identifiable {
    case varied    = "varied"
    case intensive = "intensive"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .varied:    return "Varied"
        case .intensive: return "Intensive"
        }
    }

    var description: String {
        switch self {
        case .varied:
            return "After your answer, we will automatically refresh the other flashcards for the same item, so you won't see the same word from multiple angles back-to-back. Good if you hate seeing the same word in a different way."
        case .intensive:
            return "Only the flashcard you just answered is updated. Other flashcards for the same word aren't updated and may reappear soon. Good for you over-reviewers!"
        }
    }
}

enum LocalModel: String, CaseIterable, Identifiable {
    case haiku  = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-4-6"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .haiku:  return "Haiku (fast)"
        case .sonnet: return "Sonnet (smart)"
        }
    }

    var description: String {
        switch self {
        case .haiku:  return "Faster and cheaper. Good for everyday quizzes."
        case .sonnet: return "Slower and more expensive. Better reasoning for tricky questions."
        }
    }
}

@Observable
final class UserPreferences {
    var quizStyle: QuizStyle {
        didSet { UserDefaults.standard.set(quizStyle.rawValue, forKey: Keys.quizStyle) }
    }

    var localModel: LocalModel {
        didSet { UserDefaults.standard.set(localModel.rawValue, forKey: Keys.localModel) }
    }

    /// Security-scoped bookmark for the external audio folder (e.g. the Obsidian vault).
    /// Nil means no external folder is configured; audio lookup falls back to Documents only.
    var audioFolderBookmark: Data? {
        didSet { UserDefaults.standard.set(audioFolderBookmark, forKey: Keys.audioFolderBookmark) }
    }

    init() {
        let storedStyle = UserDefaults.standard.string(forKey: Keys.quizStyle) ?? ""
        quizStyle = QuizStyle(rawValue: storedStyle) ?? .varied

        let storedModel = UserDefaults.standard.string(forKey: Keys.localModel) ?? ""
        localModel = LocalModel(rawValue: storedModel) ?? .haiku

        audioFolderBookmark = UserDefaults.standard.data(forKey: Keys.audioFolderBookmark)
    }

    private enum Keys {
        static let quizStyle          = "quizStyle"
        static let localModel         = "localModel"
        static let audioFolderBookmark = "audioFolderBookmark"
    }
}
