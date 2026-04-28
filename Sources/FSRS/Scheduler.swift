import Foundation

private let minimumStability = 0.001
private let minimumDifficulty = 1.0
private let maximumDifficulty = 10.0
private let defaultDecay = 0.1542
private let parameterBounds: [ClosedRange<Double>] = [
    minimumStability...100.0,
    minimumStability...100.0,
    minimumStability...100.0,
    minimumStability...100.0,
    1.0...10.0,
    0.001...4.0,
    0.001...4.0,
    0.001...0.75,
    0.0...4.5,
    0.0...0.8,
    0.001...3.5,
    0.001...5.0,
    0.001...0.25,
    0.001...0.9,
    0.0...4.0,
    0.0...1.0,
    1.0...6.0,
    0.0...2.0,
    0.0...2.0,
    0.0...0.8,
    0.1...0.8,
]

private struct FuzzRange {
    let start: Double
    let end: Double
    let factor: Double
}

private let fuzzRanges = [
    FuzzRange(start: 2.5, end: 7.0, factor: 0.15),
    FuzzRange(start: 7.0, end: 20.0, factor: 0.1),
    FuzzRange(start: 20.0, end: .infinity, factor: 0.05),
]

private enum NextInterval {
    case seconds(TimeInterval)
    case days(Int)
}

public struct Scheduler: Equatable, Codable, Sendable {
    public struct Parameters: Equatable, Codable, Sendable {
        public let weights: [Double]
        
        public static let `default` = try! Parameters(weights: [
            0.212, 1.2931, 2.3065, 8.2956, 6.4133,
            0.8334, 3.0194, 0.001, 1.8722, 0.1666,
            0.796, 1.4835, 0.0614, 0.2629, 1.6483,
            0.6014, 1.8729, 0.5425, 0.0912, 0.0658,
            defaultDecay,
        ])
        
        public init(weights: [Double]) throws {
            if weights.count != parameterBounds.count {
                throw FSRSError.invalidParameters([
                    .incorrectCount(expected: parameterBounds.count, actual: weights.count),
                ])
            }
            
            var issues = [ParameterValidationIssue]()
            for (index, pair) in zip(weights.indices, zip(weights, parameterBounds)) {
                let value = pair.0
                let allowed = pair.1
                if !allowed.contains(value) {
                    issues.append(.outOfRange(index: index, value: value, allowed: allowed))
                }
            }
            
            if !issues.isEmpty {
                throw FSRSError.invalidParameters(issues)
            }
            
            self.weights = weights
        }
        
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            try self.init(weights: container.decode([Double].self))
        }
        
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(weights)
        }
        
        fileprivate subscript(index: Int) -> Double {
            weights[index]
        }
    }
    
    public enum FuzzingPolicy: String, Codable, Sendable {
        case disabled
        case enabled
    }
    
    public struct Configuration: Equatable, Codable, Sendable {
        public let parameters: Parameters
        public let targetRetention: Double
        public let learningStepDurations: [Duration]
        public let relearningStepDurations: [Duration]
        public let maximumIntervalDays: Int
        public let fuzzingPolicy: FuzzingPolicy
        
        public static let `default` = try! Configuration()
        
        public init(
            parameters: Parameters = .default,
            targetRetention: Double = 0.9,
            learningStepDurations: [Duration] = [.seconds(60), .seconds(600)],
            relearningStepDurations: [Duration] = [.seconds(600)],
            maximumIntervalDays: Int = 36500,
            fuzzingPolicy: FuzzingPolicy = .enabled
        ) throws {
            guard (0..<1).contains(targetRetention) else {
                throw FSRSError.invalidConfiguration(.invalidTargetRetention(targetRetention))
            }
            for duration in learningStepDurations where duration.timeInterval <= 0 {
                throw FSRSError.invalidConfiguration(.invalidLearningStepDuration(duration))
            }
            for duration in relearningStepDurations where duration.timeInterval <= 0 {
                throw FSRSError.invalidConfiguration(.invalidRelearningStepDuration(duration))
            }
            guard maximumIntervalDays > 0 else {
                throw FSRSError.invalidConfiguration(.invalidMaximumIntervalDays(maximumIntervalDays))
            }
            
            self.parameters = parameters
            self.targetRetention = targetRetention
            self.learningStepDurations = learningStepDurations
            self.relearningStepDurations = relearningStepDurations
            self.maximumIntervalDays = maximumIntervalDays
            self.fuzzingPolicy = fuzzingPolicy
        }
        
        private enum CodingKeys: String, CodingKey {
            case parameters
            case targetRetention
            case learningStepDurations
            case relearningStepDurations
            case maximumIntervalDays
            case fuzzingPolicy
        }
        
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                parameters: container.decode(Parameters.self, forKey: .parameters),
                targetRetention: container.decode(Double.self, forKey: .targetRetention),
                learningStepDurations: container.decode([CodableDuration].self, forKey: .learningStepDurations).map(\.duration),
                relearningStepDurations: container.decode([CodableDuration].self, forKey: .relearningStepDurations).map(\.duration),
                maximumIntervalDays: container.decode(Int.self, forKey: .maximumIntervalDays),
                fuzzingPolicy: container.decode(FuzzingPolicy.self, forKey: .fuzzingPolicy)
            )
        }
        
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(parameters, forKey: .parameters)
            try container.encode(targetRetention, forKey: .targetRetention)
            try container.encode(learningStepDurations.map(CodableDuration.init), forKey: .learningStepDurations)
            try container.encode(relearningStepDurations.map(CodableDuration.init), forKey: .relearningStepDurations)
            try container.encode(maximumIntervalDays, forKey: .maximumIntervalDays)
            try container.encode(fuzzingPolicy, forKey: .fuzzingPolicy)
        }
    }
    
    public let configuration: Configuration
    
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }
    
    public func retrievability(of card: Card, at currentDate: Date = Date()) -> Double {
        guard let lastReviewedAt = card.lastReviewedAt, let memory = card.state.memory else {
            return 0
        }
        
        let elapsedDays = max(0, Self.dayDifference(from: lastReviewedAt, to: currentDate))
        return pow(1 + factor * Double(elapsedDays) / memory.stability, decay)
    }
    
    public func review(
        _ card: Card,
        rating: ReviewRating,
        at reviewedAt: Date = Date(),
        elapsed: Duration? = nil
    ) throws -> ReviewResult {
        var generator = SystemRandomNumberGenerator()
        return try review(card, rating: rating, at: reviewedAt, elapsed: elapsed, using: &generator)
    }
    
    public func review<R: RandomNumberGenerator>(
        _ card: Card,
        rating: ReviewRating,
        at reviewedAt: Date = Date(),
        elapsed: Duration? = nil,
        using generator: inout R
    ) throws -> ReviewResult {
        try review(card, rating: rating, at: reviewedAt, elapsed: elapsed) {
            Double.random(in: 0..<1, using: &generator)
        }
    }
    
    public func replay(
        _ reviewLogs: [ReviewLog],
        for card: Card
    ) throws -> Card {
        var generator = SystemRandomNumberGenerator()
        return try replay(reviewLogs, for: card, using: &generator)
    }
    
    public func replay<R: RandomNumberGenerator>(
        _ reviewLogs: [ReviewLog],
        for card: Card,
        using generator: inout R
    ) throws -> Card {
        for reviewLog in reviewLogs where reviewLog.cardID != card.id {
            throw FSRSError.mismatchedReviewLogCardID(expected: card.id, actual: reviewLog.cardID)
        }
        
        let sortedReviewLogs = reviewLogs.sorted { $0.reviewedAt < $1.reviewedAt }
        var replayedCard = Card(id: card.id, dueDate: card.dueDate)
        
        for reviewLog in sortedReviewLogs {
            replayedCard = try review(
                replayedCard,
                rating: reviewLog.rating,
                at: reviewLog.reviewedAt,
                elapsed: reviewLog.elapsed,
                using: &generator
            ).updatedCard
        }
        
        return replayedCard
    }
    
    private var decay: Double {
        -configuration.parameters[20]
    }
    
    private var factor: Double {
        pow(0.9, 1 / decay) - 1
    }
    
    private var learningStepIntervals: [TimeInterval] {
        configuration.learningStepDurations.map(\.timeInterval)
    }
    
    private var relearningStepIntervals: [TimeInterval] {
        configuration.relearningStepDurations.map(\.timeInterval)
    }
    
    private func review(
        _ card: Card,
        rating: ReviewRating,
        at reviewedAt: Date,
        elapsed: Duration?,
        randomValue: () -> Double
    ) throws -> ReviewResult {
        var updatedCard = card
        let daysSinceLastReview = updatedCard.lastReviewedAt.map { Self.dayDifference(from: $0, to: reviewedAt) }
        
        var nextInterval: NextInterval
        
        switch updatedCard.state {
            case .new:
                let memory = MemoryState(
                    stability: initialStability(for: rating),
                    difficulty: initialDifficulty(for: rating, shouldClamp: true)
                )
                (updatedCard.state, nextInterval) = learningTransition(
                    step: 0,
                    memory: memory,
                    rating: rating
                )
                
            case let .learning(step, memory):
                var nextMemoryStability = memory.stability
                var nextMemoryDifficulty = memory.difficulty
                if let daysSinceLastReview, daysSinceLastReview < 1 {
                    nextMemoryStability = shortTermStability(for: memory.stability, rating: rating)
                    nextMemoryDifficulty = nextDifficulty(from: memory.difficulty, rating: rating)
                } else {
                    nextMemoryStability = nextStability(
                        difficulty: memory.difficulty,
                        stability: memory.stability,
                        retrievability: retrievability(of: updatedCard, at: reviewedAt),
                        rating: rating
                    )
                    nextMemoryDifficulty = nextDifficulty(from: memory.difficulty, rating: rating)
                }
                
                (updatedCard.state, nextInterval) = learningTransition(
                    step: Int(step),
                    memory: .init(
                        stability: nextMemoryStability,
                        difficulty: nextMemoryDifficulty
                    ),
                    rating: rating
                )
                
            case let .review(memory):
                var nextMemoryStability = memory.stability
                var nextMemoryDifficulty = memory.difficulty
                
                if let daysSinceLastReview, daysSinceLastReview < 1 {
                    nextMemoryStability = shortTermStability(for: memory.stability, rating: rating)
                } else {
                    nextMemoryStability = nextStability(
                        difficulty: memory.difficulty,
                        stability: memory.stability,
                        retrievability: retrievability(of: updatedCard, at: reviewedAt),
                        rating: rating
                    )
                }
                nextMemoryDifficulty = nextDifficulty(from: memory.difficulty, rating: rating)
                
                let nextMemory = MemoryState(
                    stability: nextMemoryStability,
                    difficulty: nextMemoryDifficulty
                )
                switch rating {
                    case .again:
                        if relearningStepIntervals.isEmpty {
                            updatedCard.state = .review(memory: nextMemory)
                            nextInterval = .days(scheduledIntervalDays(for: nextMemory.stability))
                        } else {
                            updatedCard.state = .relearning(step: 0, memory: nextMemory)
                            nextInterval = .seconds(relearningStepIntervals[0])
                        }
                    case .hard, .good, .easy:
                        updatedCard.state = .review(memory: nextMemory)
                        nextInterval = .days(scheduledIntervalDays(for: nextMemory.stability))
                }
                
            case let .relearning(step, memory):
                var nextMemoryStability = memory.stability
                var nextMemoryDifficulty = memory.difficulty
                
                if let daysSinceLastReview, daysSinceLastReview < 1 {
                    nextMemoryStability = shortTermStability(for: memory.stability, rating: rating)
                    nextMemoryDifficulty = nextDifficulty(from: memory.difficulty, rating: rating)
                } else {
                    nextMemoryStability = nextStability(
                        difficulty: memory.difficulty,
                        stability: memory.stability,
                        retrievability: retrievability(of: updatedCard, at: reviewedAt),
                        rating: rating
                    )
                    nextMemoryDifficulty = nextDifficulty(from: memory.difficulty, rating: rating)
                }
                
                (updatedCard.state, nextInterval) = relearningTransition(
                    step: Int(step),
                    memory: .init(
                        stability: nextMemoryStability,
                        difficulty: nextMemoryDifficulty
                    ),
                    rating: rating
                )
        }
        
        if configuration.fuzzingPolicy == .enabled,
           case .review = updatedCard.state,
           case let .days(intervalDays) = nextInterval
        {
            nextInterval = .days(fuzzedIntervalDays(for: intervalDays, randomValue: randomValue))
        }
        
        switch nextInterval {
            case let .seconds(seconds):
                updatedCard.dueDate = reviewedAt.addingTimeInterval(seconds)
            case let .days(days):
                updatedCard.dueDate = reviewedAt.addingTimeInterval(Double(days) * 86_400.0)
        }
        updatedCard.lastReviewedAt = reviewedAt
        
        let reviewLog = ReviewLog(
            cardID: updatedCard.id,
            rating: rating,
            reviewedAt: reviewedAt,
            elapsed: elapsed
        )
        
        return ReviewResult(updatedCard: updatedCard, reviewLog: reviewLog)
    }
    
    private func learningTransition(
        step: Int,
        memory: MemoryState,
        rating: ReviewRating
    ) -> (CardState, NextInterval) {
        if learningStepIntervals.isEmpty || (step >= learningStepIntervals.count && [.hard, .good, .easy].contains(rating)) {
            return (.review(memory: memory), .days(scheduledIntervalDays(for: memory.stability)))
        }
        
        switch rating {
            case .again:
                return (.learning(step: 0, memory: memory), .seconds(learningStepIntervals[0]))
            case .hard:
                if step == 0 && learningStepIntervals.count == 1 {
                    return (.learning(step: 0, memory: memory), .seconds(learningStepIntervals[0] * 1.5))
                }
                if step == 0 && learningStepIntervals.count >= 2 {
                    return (
                        .learning(step: 0, memory: memory),
                        .seconds((learningStepIntervals[0] + learningStepIntervals[1]) / 2.0)
                    )
                }
                return (.learning(step: UInt(step), memory: memory), .seconds(learningStepIntervals[step]))
            case .good:
                if step + 1 == learningStepIntervals.count {
                    return (.review(memory: memory), .days(scheduledIntervalDays(for: memory.stability)))
                }
                return (
                    .learning(step: UInt(step + 1), memory: memory),
                    .seconds(learningStepIntervals[step + 1])
                )
            case .easy:
                return (.review(memory: memory), .days(scheduledIntervalDays(for: memory.stability)))
        }
    }
    
    private func relearningTransition(
        step: Int,
        memory: MemoryState,
        rating: ReviewRating
    ) -> (CardState, NextInterval) {
        if relearningStepIntervals.isEmpty || (step >= relearningStepIntervals.count && [.hard, .good, .easy].contains(rating)) {
            return (.review(memory: memory), .days(scheduledIntervalDays(for: memory.stability)))
        }
        
        switch rating {
            case .again:
                return (.relearning(step: 0, memory: memory), .seconds(relearningStepIntervals[0]))
            case .hard:
                if step == 0 && relearningStepIntervals.count == 1 {
                    return (.relearning(step: 0, memory: memory), .seconds(relearningStepIntervals[0] * 1.5))
                }
                if step == 0 && relearningStepIntervals.count >= 2 {
                    return (
                        .relearning(step: 0, memory: memory),
                        .seconds((relearningStepIntervals[0] + relearningStepIntervals[1]) / 2.0)
                    )
                }
                return (.relearning(step: UInt(step), memory: memory), .seconds(relearningStepIntervals[step]))
            case .good:
                if step + 1 == relearningStepIntervals.count {
                    return (.review(memory: memory), .days(scheduledIntervalDays(for: memory.stability)))
                }
                return (
                    .relearning(step: UInt(step + 1), memory: memory),
                    .seconds(relearningStepIntervals[step + 1])
                )
            case .easy:
                return (.review(memory: memory), .days(scheduledIntervalDays(for: memory.stability)))
        }
    }
    
    private static func dayDifference(from earlier: Date, to later: Date) -> Int {
        Int(floor((later.timeIntervalSince1970 - earlier.timeIntervalSince1970) / 86_400.0))
    }
    
    private func clampedDifficulty(_ difficulty: Double) -> Double {
        min(max(difficulty, minimumDifficulty), maximumDifficulty)
    }
    
    private func clampedStability(_ stability: Double) -> Double {
        max(stability, minimumStability)
    }
    
    private func initialStability(for rating: ReviewRating) -> Double {
        clampedStability(configuration.parameters[rating.ordinal - 1])
    }
    
    private func initialDifficulty(for rating: ReviewRating, shouldClamp: Bool) -> Double {
        let initial = configuration.parameters[4] - exp(configuration.parameters[5] * Double(rating.ordinal - 1)) + 1
        return shouldClamp ? clampedDifficulty(initial) : initial
    }
    
    private func scheduledIntervalDays(for stability: Double) -> Int {
        var interval = (stability / factor) * (pow(configuration.targetRetention, 1 / decay) - 1)
        interval = Self.swiftRound(interval)
        interval = max(interval, 1)
        interval = min(interval, Double(configuration.maximumIntervalDays))
        return Int(interval)
    }
    
    private func shortTermStability(for stability: Double, rating: ReviewRating) -> Double {
        var increase =
        exp(configuration.parameters[17] * (Double(rating.ordinal) - 3 + configuration.parameters[18]))
        * pow(stability, -configuration.parameters[19])
        
        if rating == .good || rating == .easy {
            increase = max(increase, 1.0)
        }
        
        return clampedStability(stability * increase)
    }
    
    private func nextDifficulty(from difficulty: Double, rating: ReviewRating) -> Double {
        let easyBaseline = initialDifficulty(for: .easy, shouldClamp: false)
        let deltaDifficulty = -(configuration.parameters[6] * Double(rating.ordinal - 3))
        let adjustedDifficulty = difficulty + ((10.0 - difficulty) * deltaDifficulty / 9.0)
        let next = configuration.parameters[7] * easyBaseline + (1 - configuration.parameters[7]) * adjustedDifficulty
        return clampedDifficulty(next)
    }
    
    private func nextStability(
        difficulty: Double,
        stability: Double,
        retrievability: Double,
        rating: ReviewRating
    ) -> Double {
        switch rating {
            case .again:
                return clampedStability(
                    nextForgetStability(
                        difficulty: difficulty,
                        stability: stability,
                        retrievability: retrievability
                    )
                )
            case .hard, .good, .easy:
                return clampedStability(
                    nextRecallStability(
                        difficulty: difficulty,
                        stability: stability,
                        retrievability: retrievability,
                        rating: rating
                    )
                )
        }
    }
    
    private func nextForgetStability(
        difficulty: Double,
        stability: Double,
        retrievability: Double
    ) -> Double {
        let longTerm =
        configuration.parameters[11]
        * pow(difficulty, -configuration.parameters[12])
        * (pow(stability + 1, configuration.parameters[13]) - 1)
        * exp((1 - retrievability) * configuration.parameters[14])
        
        let shortTerm = stability / exp(configuration.parameters[17] * configuration.parameters[18])
        return min(longTerm, shortTerm)
    }
    
    private func nextRecallStability(
        difficulty: Double,
        stability: Double,
        retrievability: Double,
        rating: ReviewRating
    ) -> Double {
        let hardPenalty = rating == .hard ? configuration.parameters[15] : 1.0
        let easyBonus = rating == .easy ? configuration.parameters[16] : 1.0
        
        return stability * (
            1
            + exp(configuration.parameters[8])
            * (11 - difficulty)
            * pow(stability, -configuration.parameters[9])
            * (exp((1 - retrievability) * configuration.parameters[10]) - 1)
            * hardPenalty
            * easyBonus
        )
    }
    
    private func fuzzedIntervalDays(for intervalDays: Int, randomValue: () -> Double) -> Int {
        guard intervalDays >= 3 else {
            return intervalDays
        }
        
        var delta = 1.0
        for fuzzRange in fuzzRanges {
            delta += fuzzRange.factor * max(
                min(Double(intervalDays), fuzzRange.end) - fuzzRange.start,
                0.0
            )
        }
        
        var minimumInterval = Int(Self.swiftRound(Double(intervalDays) - delta))
        var maximumInterval = Int(Self.swiftRound(Double(intervalDays) + delta))
        minimumInterval = max(2, minimumInterval)
        maximumInterval = min(maximumInterval, configuration.maximumIntervalDays)
        minimumInterval = min(minimumInterval, maximumInterval)
        
        let fuzzedDays =
        randomValue() * Double(maximumInterval - minimumInterval + 1)
        + Double(minimumInterval)
        return min(Int(Self.swiftRound(fuzzedDays)), configuration.maximumIntervalDays)
    }
    
    private static func swiftRound(_ value: Double) -> Double {
        value.rounded(.toNearestOrEven)
    }
}
