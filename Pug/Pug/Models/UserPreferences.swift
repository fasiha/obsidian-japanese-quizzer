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


enum SessionLength: String, CaseIterable, Identifiable {
    case short = "short"   // 3–5 items, chosen randomly
    case long  = "long"    // exactly 10 items

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: return "3–5 quizzes"
        case .long:  return "10 quizzes"
        }
    }

    var description: String {
        switch self {
        case .short: return "Each session picks a random number of items between 3 and 5. Good for quick reviews."
        case .long:  return "Each session always has exactly 10 items. Good for longer, more thorough practice."
        }
    }
}

enum DistractorSource: String, CaseIterable, Identifiable {
    case ai        = "ai"         // current behaviour: Haiku invents distractors freely
    case documents = "documents"  // new: pick distractors from corpus vocab

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ai:        return "Meanings picked by AI"
        case .documents: return "Meanings from documents"
        }
    }

    var description: String {
        switch self {
        case .ai:
            return "The AI chooses wrong answers from the same semantic area. Good for testing fine meaning distinctions."
        case .documents:
            return "Wrong answers are taken from words in your reading material. Avoids comparing English words you don't know in Japanese."
        }
    }
}

@Observable
final class UserPreferences {
    var quizStyle: QuizStyle {
        didSet { UserDefaults.standard.set(quizStyle.rawValue, forKey: Keys.quizStyle) }
    }


    var sessionLength: SessionLength {
        didSet { UserDefaults.standard.set(sessionLength.rawValue, forKey: Keys.sessionLength) }
    }

    var distractorSource: DistractorSource {
        didSet { UserDefaults.standard.set(distractorSource.rawValue, forKey: Keys.distractorSource) }
    }

    /// Security-scoped bookmark for the external audio folder (e.g. the Obsidian vault).
    /// Nil means no external folder is configured; audio lookup falls back to Documents only.
    var audioFolderBookmark: Data? {
        didSet { UserDefaults.standard.set(audioFolderBookmark, forKey: Keys.audioFolderBookmark) }
    }

    init() {
        let storedStyle = UserDefaults.standard.string(forKey: Keys.quizStyle) ?? ""
        quizStyle = QuizStyle(rawValue: storedStyle) ?? .varied


        audioFolderBookmark = UserDefaults.standard.data(forKey: Keys.audioFolderBookmark)

        let storedLength = UserDefaults.standard.string(forKey: Keys.sessionLength) ?? ""
        sessionLength = SessionLength(rawValue: storedLength) ?? .short

        let storedDistractor = UserDefaults.standard.string(forKey: Keys.distractorSource) ?? ""
        distractorSource = DistractorSource(rawValue: storedDistractor) ?? .ai
    }

    private enum Keys {
        static let quizStyle          = "quizStyle"
        static let audioFolderBookmark = "audioFolderBookmark"
        static let sessionLength      = "sessionLength"
        static let distractorSource   = "distractorSource"
    }
}
