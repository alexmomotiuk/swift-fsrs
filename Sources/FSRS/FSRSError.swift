import Foundation

public enum ParameterValidationIssue: Error, Equatable {
    case incorrectCount(expected: Int, actual: Int)
    case outOfRange(index: Int, value: Double, allowed: ClosedRange<Double>)
}

public enum ConfigurationValidationError: Error, Equatable {
    case invalidTargetRetention(Double)
    case invalidLearningStepDuration(Duration)
    case invalidRelearningStepDuration(Duration)
    case invalidMaximumIntervalDays(Int)
}

public enum CardStateValidationError: Error, Equatable {
    case newCardCannotHaveLastReviewedAt
    case reviewedCardRequiresLastReviewedAt
}

public enum OptimizerError: Error, Equatable {
    case insufficientReviewLogsForRetention(minimum: Int, actual: Int)
    case missingReviewDuration(cardID: UUID)
}

public enum FSRSError: Error, Equatable {
    case invalidParameters([ParameterValidationIssue])
    case invalidConfiguration(ConfigurationValidationError)
    case invalidCardState(CardStateValidationError)
    case mismatchedReviewLogCardID(expected: UUID, actual: UUID)
}
