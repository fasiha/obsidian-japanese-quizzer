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

@Observable
final class UserPreferences {
    var quizStyle: QuizStyle {
        didSet { UserDefaults.standard.set(quizStyle.rawValue, forKey: Keys.quizStyle) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Keys.quizStyle) ?? ""
        quizStyle = QuizStyle(rawValue: stored) ?? .varied
    }

    private enum Keys {
        static let quizStyle = "quizStyle"
    }
}
