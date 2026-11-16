/// Work already completed by the current stage, not an estimate of total job time.
struct SpeakerProcessingProgress: Equatable, Sendable {
    let completedUnits: Int
    let totalUnits: Int

    var isValid: Bool {
        totalUnits > 0 && completedUnits >= 0 && completedUnits <= totalUnits
    }

    var percent: Int {
        guard isValid else { return 0 }
        let product = completedUnits.multipliedFullWidth(by: 100)
        return totalUnits.dividingFullWidth(product).quotient
    }
}
