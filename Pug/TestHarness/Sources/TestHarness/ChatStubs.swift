// ChatStubs.swift
// Minimal stubs for ChatDB and ChatContext so the symlinked app files compile in the
// TestHarness target. The harness saves LLM conversations to /tmp log files instead of
// chat.sqlite, so ChatDB is always nil at runtime and these stubs are never called.

import Foundation

enum ChatContext: Sendable {
    case wordExplore(wordId: String)
    case transitivePairDetail(pairId: String)
    case grammarDetail(topicId: String)
    case vocabQuiz(wordId: String, facet: String, sessionId: String)
    case grammarQuiz(topicId: String, facet: String)
    case grammarQuizGeneration(topicId: String)

    var tag: String {
        switch self {
        case .wordExplore(let id):                          return "word:\(id)"
        case .transitivePairDetail(let id):                 return "pair:\(id)"
        case .grammarDetail(let id):                        return "grammar:\(id)"
        case .vocabQuiz(let id, let facet, let sessionId):  return "quiz:\(id):\(facet):\(sessionId)"
        case .grammarQuiz(let id, let facet):               return "quiz:\(id):\(facet)"
        case .grammarQuizGeneration(let id):                return "quiz-gen:\(id)"
        }
    }
}

final class ChatDB: Sendable {
    func append(context: ChatContext, role: String, content: String, templateId: String?) async {}
}
