// ProblemReportStub.swift
// Minimal stub for TestHarness — provides only the model type used by QuizSession.
// The SwiftUI banner view in the main target is intentionally excluded here.

import Foundation

struct ProblemReport {
    let message: String
    let timestamp: Date

    static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm z"
        return f
    }()
}
