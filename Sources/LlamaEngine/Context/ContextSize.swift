import Foundation

/// Context-window presets offered in the pickers, plus a display formatter and the
/// right-sizing helper. Pure, so it is unit-tested.
public enum ContextSize {
    /// Common `num_ctx` values. The high end (256K–1M) suits long-context models on
    /// beefier servers; the model/server clamps anything it can't actually support.
    public static let presets = [4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576]

    public static func label(_ n: Int) -> String {
        if n >= 1_048_576 && n % 1_048_576 == 0 { return "\(n / 1_048_576)M" }
        if n >= 1024 && n % 1024 == 0 { return "\(n / 1024)K" }
        return "\(n)"
    }

    /// The smallest preset window that holds `needed` tokens without exceeding
    /// `ceiling` (the user's chosen size, itself capped to the model's real limit).
    /// Snapping to presets keeps `num_ctx` stable across similar turns so Ollama's
    /// prompt cache stays warm, while still sending only as much window as the request
    /// actually needs — less KV-cache memory and faster loads on modest hardware.
    public static func rightSized(needed: Int, ceiling: Int) -> Int {
        let cap = max(1, ceiling)
        let n = max(1, needed)
        if n >= cap { return cap }
        if let preset = presets.first(where: { $0 >= n && $0 <= cap }) { return preset }
        return cap
    }
}
