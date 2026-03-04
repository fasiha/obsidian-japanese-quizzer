// EbisuModel.swift
// Swift port of ebisu-js (https://github.com/fasiha/ebisu-js)
// Uses fractional scores (0–1) via the noisy-quiz single-trial model.

import Darwin
import Foundation

// MARK: - Types

struct EbisuModel: Codable, Equatable, Sendable {
    var alpha: Double
    var beta: Double
    var t: Double      // halflife in hours
}

enum EbisuError: Error, LocalizedError {
    case numericalInstability(String)
    case convergenceFailed(String)
    var errorDescription: String? {
        switch self {
        case .numericalInstability(let m): return "Ebisu numerical instability: \(m)"
        case .convergenceFailed(let m): return "Ebisu convergence failure: \(m)"
        }
    }
}

// MARK: - Public API

/// Expected recall probability, `tnow` hours after last review.
/// exact=true returns linear probability (0–1); false returns log-probability.
nonisolated func predictRecall(_ prior: EbisuModel, tnow: Double, exact: Bool = false) -> Double {
    let dt = tnow / prior.t
    let ret = betalnRatio(prior.alpha + dt, prior.alpha, prior.beta)
    return exact ? exp(ret) : ret
}

/// Update a prior with a quiz result. `successes` ∈ [0,1], `total` must be 1.
/// Returns a new model with updated halflife. Throws on numerical instability.
nonisolated func updateRecall(
    _ prior: EbisuModel,
    successes: Double,
    total: Int = 1,
    tnow: Double
) throws -> EbisuModel {
    guard total == 1 else { fatalError("updateRecall: only total=1 is supported") }
    return try updateRecallSingle(prior, result: successes, tnow: tnow)
}

/// Default initial model for a new word.
/// `a` is the Beta shape parameter (symmetric α = β). Halflife `t` is in hours.
nonisolated func defaultModel(halflife t: Double, a: Double = 4.0) -> EbisuModel {
    EbisuModel(alpha: a, beta: a, t: t)
}

/// Return a new model with the halflife scaled by `scale`.
/// Use scale > 1 to push out (word is easy), scale < 1 to pull in (word is hard).
nonisolated func rescaleHalflife(_ prior: EbisuModel, scale: Double = 1.0) throws -> EbisuModel {
    let oldHalflife = try modelToPercentileDecay(prior)
    let dt = oldHalflife / prior.t
    let logDenominator = betaln(prior.alpha, prior.beta)
    let logm2 = betaln(prior.alpha + 2 * dt, prior.beta) - logDenominator
    let m2 = exp(logm2)
    let newAB = 1.0 / (8 * m2 - 2) - 0.5
    guard newAB > 0 else {
        throw EbisuError.numericalInstability("non-positive α/β in rescaleHalflife")
    }
    return EbisuModel(alpha: newAB, beta: newAB, t: oldHalflife * scale)
}

// MARK: - Private math helpers

private nonisolated func betalnRatio(_ a1: Double, _ a: Double, _ b: Double) -> Double {
    lgamma(a1) - lgamma(a1 + b) + lgamma(a + b) - lgamma(a)
}

private nonisolated func betaln(_ a: Double, _ b: Double) -> Double {
    lgamma(a) + lgamma(b) - lgamma(a + b)
}

/// log-sum-exp with arbitrary signs: returns (log|∑ b[i]·exp(a[i])|, sign).
private nonisolated func logsumexp(_ a: [Double], _ b: [Double]) -> (value: Double, sign: Double) {
    let aMax = a.max()!
    var s = 0.0
    for i in 0..<a.count { s += b[i] * exp(a[i] - aMax) }
    let sgn = s >= 0 ? 1.0 : -1.0
    return (log(s * sgn) + aMax, sgn)
}

private nonisolated func meanVarToBeta(_ mean: Double, _ v: Double) -> (Double, Double) {
    let tmp = (mean * (1 - mean)) / v - 1
    return (mean * tmp, (1 - mean) * tmp)
}

// MARK: - Single-trial update (port of _updateRecallSingle from ebisu-js)
//
// This implements the "noisy quiz" model: a fractional score ∈ [0,1]
// represents the probability that the user really recalled the item.

private nonisolated func updateRecallSingle(
    _ prior: EbisuModel,
    result: Double,
    tnow: Double,
    q0 override: Double? = nil
) throws -> EbisuModel {
    guard (0...1).contains(result) else {
        throw EbisuError.numericalInstability("result \(result) not in [0,1]")
    }
    let (alpha, beta, t) = (prior.alpha, prior.beta, prior.t)
    let z = result > 0.5
    let q1 = z ? result : 1 - result
    let q0 = override ?? (1 - q1)
    let dt = tnow / t
    let (c, d): (Double, Double) = z ? (q1 - q0, q0) : (q0 - q1, 1 - q0)

    // Use log domain throughout for numerical stability with large dt.
    let logden = logsumexp([betaln(alpha + dt, beta), betaln(alpha, beta)], [c, d]).value

    func logmoment(_ N: Double, _ et: Double) -> Double {
        if d != 0 {
            return logsumexp(
                [betaln(alpha + dt + N * dt * et, beta),
                 betaln(alpha + N * dt * et, beta)],
                [c, d]
            ).value - logden
        }
        // d == 0: simplified path (perfect recall, q0 = 0)
        return log(c) + betaln(alpha + dt + N * dt * et, beta) - logden
    }

    // logmoment(1, et) starts at ~0 (et=0) and decreases to −∞ (et→∞).
    // Find et where logmoment(1, et) = log(0.5) via bisection.
    let target = log(0.5)

    // Find upper bracket
    var upper = 1.0
    for _ in 0..<64 {
        let v = logmoment(1, upper)
        guard !v.isNaN else { upper /= 2; break }
        if v < target { break }
        upper *= 2
    }

    guard let et = bisect({ logmoment(1, $0) - target }, lo: 0, hi: upper) else {
        throw EbisuError.convergenceFailed(
            "updateRecallSingle: bisection failed (α=\(alpha), β=\(beta), t=\(t), tnow=\(tnow), result=\(result))")
    }
    let tback = et * tnow

    let mean = exp(logmoment(1, et))
    let m2   = exp(logmoment(2, et))
    let variance = m2 - mean * mean
    let (na, nb) = meanVarToBeta(mean, variance)
    guard na > 0, nb > 0, na.isFinite, nb.isFinite else {
        throw EbisuError.numericalInstability("invalid α=\(na) β=\(nb) after update")
    }
    return EbisuModel(alpha: na, beta: nb, t: tback)
}

// MARK: - Percentile decay (log-delta bisection, inspired by ebisu-java)

/// Find the time (in hours) at which recall probability equals `percentile`.
/// Default percentile=0.5 gives the halflife.
private nonisolated func modelToPercentileDecay(_ model: EbisuModel, percentile: Double = 0.5) throws -> Double {
    let logBab = betaln(model.alpha, model.beta)
    let logPct = log(percentile)
    // f(lndelta) = betaln(α + exp(lndelta), β) - logBab - logPct
    // f is monotone decreasing: positive for small lndelta, negative for large.
    let f: (Double) -> Double = { lndelta in
        betaln(model.alpha + exp(lndelta), model.beta) - logBab - logPct
    }
    // Expand bracket until sign change is found
    var blow = -3.0, bhigh = 3.0
    let width = 6.0
    for _ in 0..<20 {
        if f(blow) > 0 && f(bhigh) < 0 { break }
        if f(blow) > 0 && f(bhigh) > 0 { blow = bhigh; bhigh += width }
        if f(blow) < 0 && f(bhigh) < 0 { bhigh = blow; blow -= width }
    }
    guard f(blow) > 0 && f(bhigh) < 0 else {
        throw EbisuError.convergenceFailed("modelToPercentileDecay: failed to bracket halflife")
    }
    guard let lndelta = bisect(f, lo: blow, hi: bhigh) else {
        throw EbisuError.convergenceFailed("modelToPercentileDecay: bisection failed")
    }
    return exp(lndelta) * model.t
}

// MARK: - Bisection root-finder

/// Find x in [lo, hi] where f(x) = 0, given f(lo) and f(hi) have opposite signs.
private nonisolated func bisect(
    _ f: (Double) -> Double,
    lo: Double,
    hi: Double,
    tolerance: Double = 1e-10
) -> Double? {
    var lo = lo, hi = hi
    var flo = f(lo)
    guard flo * f(hi) <= 0 else { return nil }
    for _ in 0..<200 {
        if hi - lo < tolerance { return (lo + hi) / 2 }
        let mid = (lo + hi) / 2
        let fmid = f(mid)
        guard !fmid.isNaN else { return nil }
        if flo * fmid <= 0 { hi = mid } else { lo = mid; flo = fmid }
    }
    return (lo + hi) / 2
}
