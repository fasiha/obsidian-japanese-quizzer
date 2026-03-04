// EbisuTests.swift
// Unit tests for the Ebisu Swift port, validated against the ebisu-js reference
// test suite (test.json). Loads ebisu-test.json from the same directory as this
// source file — works because Swift unit tests run on the host macOS machine
// and #file is a valid filesystem path at test time.

import Testing
import Foundation
@testable import AsteroidalDust

// MARK: - Test data types

private struct TestEntry {
    let operation: String
    let prior: EbisuModel
    // update fields
    let total: Int
    let successes: Double
    let tnow: Double
    let post: (alpha: Double, beta: Double, t: Double)?
    // predict fields
    let mean: Double?
}

// MARK: - Test suite

@Suite("Ebisu Math")
struct EbisuTests {

    // MARK: - Reference tests (ebisu-js test.json)

    @Test("predictRecall matches ebisu-js reference (10 cases)")
    func predictRecallReference() throws {
        let entries = try loadTestJSON()
        let predicts = entries.filter { $0.operation == "predict" }
        #expect(predicts.count == 10, "expected 10 predict entries in test.json")

        for e in predicts {
            let actual = predictRecall(e.prior, tnow: e.tnow, exact: true)
            let err = relerr(actual, e.mean!)
            #expect(err < 3e-3,
                "predictRecall(\(e.prior), tnow=\(e.tnow)): relerr=\(fmt(err)), got=\(actual), want=\(e.mean!)")
        }
    }

    @Test("updateRecall (total=1) matches ebisu-js reference (625 cases)")
    func updateRecallReference() throws {
        let entries = try loadTestJSON()
        let updates = entries.filter { $0.operation == "update" && $0.total == 1 }
        #expect(updates.count == 625, "expected 625 update-with-total-1 entries in test.json")

        for e in updates {
            let actual = try updateRecall(e.prior, successes: e.successes, total: 1, tnow: e.tnow)
            let (ea, eb, et) = e.post!
            let err = max(relerr(actual.alpha, ea), relerr(actual.beta, eb), relerr(actual.t, et))
            #expect(err < 3e-3,
                "updateRecall(\(e.prior), s=\(e.successes), tnow=\(e.tnow)): relerr=\(fmt(err))")
        }
    }

    // MARK: - Stress tests (from test.js #20: very long elapsed times)

    @Test("updateRecall handles very long elapsed times without throwing")
    func updateRecallSuperLongT() throws {
        let scores = [1.0 / 6, 1.0 / 3, 0.5, 2.0 / 3, 5.0 / 6]
        let cases: [(EbisuModel, Double)] = [
            (EbisuModel(alpha: 4, beta: 4, t: 0.0607), 3.56),
            (EbisuModel(alpha: 4, beta: 4, t: 0.24),   14.39),
            (EbisuModel(alpha: 4, beta: 4, t: 1),      1_000),
            (EbisuModel(alpha: 4, beta: 4, t: 1),      10_000),
            (EbisuModel(alpha: 4, beta: 4, t: 1),      100_000),
            (EbisuModel(alpha: 2, beta: 2, t: 10),     10_000),
            (EbisuModel(alpha: 2, beta: 2, t: 10),     1_000),
            (EbisuModel(alpha: 2, beta: 2, t: 10),     100),
        ]
        for (model, tnow) in cases {
            for score in scores {
                let result = try updateRecall(model, successes: score, total: 1, tnow: tnow)
                #expect(result.alpha > 0 && result.beta > 0 && result.t > 0,
                    "\(model) score=\(score) tnow=\(tnow): invalid result \(result)")
            }
        }
    }

    // MARK: - Smoke tests for defaultModel and rescaleHalflife

    @Test("defaultModel creates symmetric Beta at the given halflife")
    func testDefaultModel() {
        let m = defaultModel(halflife: 24)
        #expect(m.alpha == 4.0)
        #expect(m.beta  == 4.0)
        #expect(m.t     == 24.0)
        // At exactly t=24h, recall should be 0.5
        let recall = predictRecall(m, tnow: 24.0, exact: true)
        #expect(abs(recall - 0.5) < 1e-10)
    }

    @Test("rescaleHalflife doubles the halflife correctly")
    func testRescaleHalflife() throws {
        let m = defaultModel(halflife: 24)            // alpha=beta=4, t=24h
        let scaled = try rescaleHalflife(m, scale: 2) // should give t≈48h

        // Resulting model should remain symmetric and have halflife ≈ 48h
        #expect(abs(scaled.alpha - scaled.beta) < 1e-10, "rescaled model should be symmetric")
        #expect(relerr(scaled.t, 48.0) < 1e-3, "rescaled halflife should be ≈ 48h, got \(scaled.t)")

        // Confirm recall at the new halflife is ≈ 0.5
        let recall = predictRecall(scaled, tnow: scaled.t, exact: true)
        #expect(abs(recall - 0.5) < 1e-3, "recall at halflife should be 0.5, got \(recall)")
    }

    // MARK: - JSON loading helpers

    private func loadTestJSON() throws -> [TestEntry] {
        // #file is the path of this source file at compile time; at test time on macOS
        // this path is valid because tests run on the host machine.
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("ebisu-test.json")
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data) as! [[Any]]

        return raw.compactMap { entry -> TestEntry? in
            guard entry.count >= 4,
                  let op = entry[0] as? String,
                  let priorArr = doubles(entry[1]), priorArr.count == 3
            else { return nil }

            let prior = EbisuModel(alpha: priorArr[0], beta: priorArr[1], t: priorArr[2])

            if op == "predict" {
                guard let argsArr = doubles(entry[2]), argsArr.count == 1,
                      let resultDict = entry[3] as? [String: Any],
                      let mean = (resultDict["mean"] as? NSNumber)?.doubleValue
                else { return nil }
                return TestEntry(operation: "predict", prior: prior,
                                 total: 1, successes: 0, tnow: argsArr[0],
                                 post: nil, mean: mean)

            } else if op == "update" {
                guard let argsArr = doubles(entry[2]), argsArr.count == 3,
                      let resultDict = entry[3] as? [String: Any],
                      let postArr = doubles(resultDict["post"]), postArr.count == 3
                else { return nil }
                return TestEntry(operation: "update", prior: prior,
                                 total: Int(argsArr[1]),
                                 successes: argsArr[0], tnow: argsArr[2],
                                 post: (postArr[0], postArr[1], postArr[2]),
                                 mean: nil)
            }
            return nil
        }
    }

    /// Safely extract [Double] from Any (handles JSON integer/float NSNumber mix).
    private func doubles(_ val: Any?) -> [Double]? {
        guard let arr = val as? [Any] else { return nil }
        let result = arr.compactMap { ($0 as? NSNumber)?.doubleValue }
        return result.count == arr.count ? result : nil
    }

    // MARK: - Numeric helpers

    private func relerr(_ actual: Double, _ expected: Double) -> Double {
        expected == 0 ? abs(actual) : abs(actual - expected) / abs(expected)
    }

    private func fmt(_ x: Double) -> String { String(format: "%.2e", x) }
}
