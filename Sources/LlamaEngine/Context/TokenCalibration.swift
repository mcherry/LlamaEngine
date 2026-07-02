import Foundation

/// Learns a per-model correction factor for `TokenEstimator`'s cheap chars/4 guess by
/// comparing it to the real `prompt_eval_count` Ollama reports each turn. Dense or
/// technical text tokenizes to more tokens than chars/4 predicts, so a document can
/// fill far more of the window than the estimate suggests — the cause of mid-reply
/// truncation. The factor (actual ÷ estimated tokens) is smoothed across turns and
/// clamped so budgeting reflects how a model *actually* tokenizes, turning a static
/// guess into a measurement that improves after the first reply.
///
/// The factor is only ever applied to make budgets **more** conservative (clamped to
/// ≥ 1), so a noisy under-estimate can never trick the planner into overfilling the
/// window. Persisted per model name so it carries across sessions and launches.
@MainActor
public final class TokenCalibrator {
    private var factors: [String: Double]
    private let defaultsKey = "tokenCalibrationFactors"

    /// EMA weight for each new observation: high enough to adapt within a few turns,
    /// low enough to smooth over the per-turn noise of individual prompts.
    nonisolated static let smoothing = 0.3

    /// Clamp range for the stored factor. The floor of 1.0 keeps calibration purely
    /// conservative (it never shrinks an estimate); the ceiling guards against a single
    /// pathological prompt distorting the budget.
    nonisolated static let range = 1.0...2.5

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        factors = (userDefaults.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
    }

    private let userDefaults: UserDefaults

    /// The multiplier to apply to a raw chars/4 estimate for `model` (1.0 until learned).
    public func scale(for model: String) -> Double {
        factors[model] ?? 1.0
    }

    /// Folds one observation (a real prompt-token count vs. our raw estimate) into the
    /// model's factor and persists it. No-ops on non-positive inputs.
    public func record(model: String, rawEstimate: Int, actualTokens: Int) {
        guard !model.isEmpty,
              let updated = Self.updatedFactor(current: factors[model],
                                               rawEstimate: rawEstimate,
                                               actualTokens: actualTokens) else { return }
        factors[model] = updated
        userDefaults.set(factors, forKey: defaultsKey)
    }

    /// Pure EMA update, clamped to `range`. Returns `nil` (no change) for invalid
    /// inputs so it can be unit-tested without any storage.
    nonisolated static func updatedFactor(current: Double?,
                                          rawEstimate: Int,
                                          actualTokens: Int) -> Double? {
        guard rawEstimate > 0, actualTokens > 0 else { return nil }
        let observed = Double(actualTokens) / Double(rawEstimate)
        let blended = current.map { $0 + smoothing * (observed - $0) } ?? observed
        return min(max(blended, range.lowerBound), range.upperBound)
    }
}
