/// Display-only efficiency: session, matching day, then reconstructed stages. Kotlin: nightEfficiencyPct.
func nightEfficiencyPct(sessionEfficiency: Double?, dayEfficiency: Double?,
                        asleep: Double, timeInBed: Double) -> Double? {
    if let stored = sessionEfficiency ?? dayEfficiency {
        return stored <= 1.0 ? stored * 100 : stored
    }
    guard timeInBed > 0 else { return nil }
    return min(100, asleep / timeInBed * 100)
}
