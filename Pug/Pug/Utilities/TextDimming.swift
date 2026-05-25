// TextDimming.swift
// Multi-sequence LCS-based dim/bright run computation for grammar quiz choice buttons.
//
// Given N choice strings, characters that belong to the longest common subsequence
// shared by all N strings are marked "dim" (they appear in every choice). Characters
// that diverge across choices are marked "bright" so the eye goes straight to the
// meaningful differences.

import Foundation

// MARK: - Public types

/// A contiguous run of characters in a choice string, tagged as shared (dim) or unique (bright).
struct DimRun: Equatable {
    let text: String
    let dim: Bool
}

// MARK: - Multi-sequence LCS dimming

/// Returns one array of `DimRun` per choice.
///
/// Algorithm:
/// 1. Compute the multi-sequence common subsequence by iterating pairwise LCS:
///    `shared = LCS(LCS(LCS(choices[0], choices[1]), choices[2]), choices[3])`
///    Each step can only remove characters, so the final result is guaranteed to be
///    a common subsequence of all inputs (though not necessarily the longest possible one).
/// 2. For each choice, greedily align it against `shared` left-to-right: a character
///    that matches the next unmatched position in `shared` is dim; all others are bright.
/// 3. Consecutive characters with the same dim/bright tag are merged into one run.
func multiSequenceDimRuns(choices: [String]) -> [[DimRun]] {
    guard choices.count >= 2 else {
        return choices.map { [DimRun(text: $0, dim: false)] }
    }

    // Step 1: iterative pairwise LCS to find the shared subsequence.
    var shared = Array(choices[0])
    for other in choices.dropFirst() {
        shared = lcsCharacters(shared, Array(other))
    }

    // Step 2 & 3: align each choice against shared, emit dim/bright runs.
    return choices.map { choice in
        dimRunsAligning(string: Array(choice), shared: shared)
    }
}

// MARK: - LCS helpers

/// Standard O(mn) longest-common-subsequence of two character arrays.
private func lcsCharacters(_ a: [Character], _ b: [Character]) -> [Character] {
    let m = a.count, n = b.count
    guard m > 0, n > 0 else { return [] }

    // dp[i][j] = length of LCS of a[0..<i] and b[0..<j]
    var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
    for i in 1...m {
        for j in 1...n {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
            }
        }
    }

    // Backtrack to recover the actual subsequence.
    var result: [Character] = []
    var i = m, j = n
    while i > 0, j > 0 {
        if a[i - 1] == b[j - 1] {
            result.append(a[i - 1])
            i -= 1; j -= 1
        } else if dp[i - 1][j] >= dp[i][j - 1] {
            i -= 1
        } else {
            j -= 1
        }
    }
    return result.reversed()
}

/// Greedily aligns `string` against `shared` and returns dim/bright runs.
/// A character in `string` is dim when it is the next unmatched character in `shared`.
private func dimRunsAligning(string: [Character], shared: [Character]) -> [DimRun] {
    var runs: [DimRun] = []
    var si = 0  // next position to match in shared
    var currentText = ""
    var currentDim: Bool? = nil

    for ch in string {
        let isDim = si < shared.count && ch == shared[si]
        if isDim { si += 1 }

        if currentDim == nil {
            currentDim = isDim
            currentText = String(ch)
        } else if isDim == currentDim {
            currentText.append(ch)
        } else {
            runs.append(DimRun(text: currentText, dim: currentDim!))
            currentText = String(ch)
            currentDim = isDim
        }
    }
    if !currentText.isEmpty {
        runs.append(DimRun(text: currentText, dim: currentDim ?? false))
    }
    return runs
}
