import Foundation

public struct Optimizer: Sendable {
    public struct Progress: Equatable, Sendable {
        public let completedEpochs: Int
        public let totalEpochs: Int
        public let bestLoss: Double
    }

    private static let parameterBounds: [ClosedRange<Double>] = [
        0.001...100.0,
        0.001...100.0,
        0.001...100.0,
        0.001...100.0,
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

    private static let adamBeta1 = 0.9
    private static let adamBeta2 = 0.999
    private static let adamEpsilon = 1e-8
    private static let gradientDeltaScale = 1e-4
    private static let gradientMinimumDelta = 1e-5

    private let reviewLogs: [ReviewLog]
    private let histories: [ReviewHistory]
    private let configurationTemplate: Scheduler.Configuration
    private let trainingEpochs: Int
    private let miniBatchSize: Int
    private let learningRate: Double
    private let maximumSequenceLength: Int

    public init(
        reviewLogs: [ReviewLog],
        configuration: Scheduler.Configuration = .default,
        trainingEpochs: Int = 5,
        miniBatchSize: Int = 512,
        learningRate: Double = 4e-2,
        maximumSequenceLength: Int = 64
    ) {
        self.reviewLogs = reviewLogs
        self.histories = Self.makeHistories(from: reviewLogs)
        configurationTemplate = configuration
        self.trainingEpochs = trainingEpochs
        self.miniBatchSize = miniBatchSize
        self.learningRate = learningRate
        self.maximumSequenceLength = maximumSequenceLength
    }

    public func computeOptimalParameters(
        reportingProgress progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) -> Scheduler.Parameters {
        let startingParameters = configurationTemplate.parameters
        let reviewCount = countOptimizableReviews()
        guard reviewCount >= miniBatchSize else {
            return startingParameters
        }

        let totalOptimizationSteps = max(1, Int(ceil(Double(reviewCount) / Double(miniBatchSize))) * trainingEpochs)
        var rng = SeededGenerator(state: 42)
        var currentWeights = startingParameters.weights
        var bestWeights = currentWeights
        var bestLoss = Double.infinity
        var firstMoment = Array(repeating: 0.0, count: currentWeights.count)
        var secondMoment = Array(repeating: 0.0, count: currentWeights.count)
        var optimizationStep = 0

        for epoch in 0..<trainingEpochs {
            var epochHistories = histories
            rng.shuffle(&epochHistories)

            var currentScheduler = scheduler(parameters: currentWeights, targetRetention: configurationTemplate.targetRetention)
            var cardStates = [UUID: Card]()
            var batchInitialCards = [UUID: Card]()
            var batchEvents = [BatchEvent]()
            var batchLossCount = 0

            for history in epochHistories {
                let reviews = Array(history.reviews.prefix(maximumSequenceLength))
                guard let firstReview = reviews.first else {
                    continue
                }

                var card = cardStates[history.cardID] ?? Card(id: history.cardID, dueDate: firstReview.reviewedAt)

                for review in reviews {
                    if batchInitialCards[history.cardID] == nil {
                        batchInitialCards[history.cardID] = card
                    }

                    let countsForLoss = card.lastReviewedAt.map { dayDifference(from: $0, to: review.reviewedAt) > 0 } ?? false
                    if countsForLoss {
                        batchLossCount += 1
                    }
                    batchEvents.append(BatchEvent(review: review, cardID: history.cardID, countsForLoss: countsForLoss))

                    card = (try? currentScheduler.review(
                        card,
                        rating: review.rating,
                        at: review.reviewedAt,
                        elapsed: nil
                    ).updatedCard) ?? card
                    cardStates[history.cardID] = card

                    if batchLossCount == miniBatchSize {
                        optimizationStep += 1
                        updateParameters(
                            batch: TrainingBatch(initialCards: batchInitialCards, events: batchEvents),
                            weights: &currentWeights,
                            firstMoment: &firstMoment,
                            secondMoment: &secondMoment,
                            optimizationStep: optimizationStep,
                            totalOptimizationSteps: totalOptimizationSteps
                        )
                        currentScheduler = scheduler(parameters: currentWeights, targetRetention: configurationTemplate.targetRetention)
                        batchInitialCards.removeAll(keepingCapacity: true)
                        batchEvents.removeAll(keepingCapacity: true)
                        batchLossCount = 0
                    }
                }
            }

            if !batchEvents.isEmpty {
                optimizationStep += 1
                updateParameters(
                    batch: TrainingBatch(initialCards: batchInitialCards, events: batchEvents),
                    weights: &currentWeights,
                    firstMoment: &firstMoment,
                    secondMoment: &secondMoment,
                    optimizationStep: optimizationStep,
                    totalOptimizationSteps: totalOptimizationSteps
                )
            }

            let epochLoss = computeBatchLoss(parameters: parameterSet(from: currentWeights))
            if epochLoss < bestLoss {
                bestLoss = epochLoss
                bestWeights = currentWeights
            }
            progressHandler?(.init(completedEpochs: epoch + 1, totalEpochs: trainingEpochs, bestLoss: bestLoss))
        }

        return parameterSet(from: bestWeights)
    }

    public func computeOptimalRetention(parameters: Scheduler.Parameters) throws -> Double {
        guard reviewLogs.count >= 512 else {
            throw OptimizerError.insufficientReviewLogsForRetention(minimum: 512, actual: reviewLogs.count)
        }
        for reviewLog in reviewLogs where reviewLog.elapsed == nil {
            throw OptimizerError.missingReviewDuration(cardID: reviewLog.cardID)
        }

        let probabilitiesAndCosts = computeProbabilitiesAndCosts()
        let candidateRetentions = [0.7, 0.75, 0.8, 0.85, 0.9, 0.95]
        var bestRetention = candidateRetentions[0]
        var bestCost = Double.infinity

        for retention in candidateRetentions {
            let cost = simulateCost(
                desiredRetention: retention,
                parameters: parameters,
                numberOfCards: 1000,
                probabilitiesAndCosts: probabilitiesAndCosts
            )
            if cost < bestCost {
                bestCost = cost
                bestRetention = retention
            }
        }

        return bestRetention
    }

    func computeBatchLoss(parameters: Scheduler.Parameters) -> Double {
        let scheduler = scheduler(parameters: parameters.weights, targetRetention: configurationTemplate.targetRetention)
        var losses = [Double]()

        for history in histories {
            let reviews = Array(history.reviews.prefix(maximumSequenceLength))
            guard let firstReview = reviews.first else {
                continue
            }

            var card = Card(id: history.cardID, dueDate: firstReview.reviewedAt)
            for review in reviews {
                let prediction = scheduler.retrievability(of: card, at: review.reviewedAt)
                if let lastReviewedAt = card.lastReviewedAt,
                   dayDifference(from: lastReviewedAt, to: review.reviewedAt) > 0
                {
                    losses.append(binaryCrossEntropy(prediction: prediction, target: review.recall))
                }

                card = (try? scheduler.review(card, rating: review.rating, at: review.reviewedAt, elapsed: nil).updatedCard) ?? card
            }
        }

        guard !losses.isEmpty else {
            return 0
        }
        return losses.reduce(0, +) / Double(losses.count)
    }

    func computeProbabilitiesAndCosts() -> ProbabilitiesAndCosts {
        let sortedLogs = reviewLogs.sorted {
            if $0.cardID == $1.cardID {
                return $0.reviewedAt < $1.reviewedAt
            }
            return $0.cardID.uuidString < $1.cardID.uuidString
        }

        var seenCards = Set<UUID>()
        var firstLogs = [ReviewLog]()
        var laterLogs = [ReviewLog]()

        for reviewLog in sortedLogs {
            if seenCards.insert(reviewLog.cardID).inserted {
                firstLogs.append(reviewLog)
            } else {
                laterLogs.append(reviewLog)
            }
        }

        return ProbabilitiesAndCosts(
            firstRatingProbabilities: ratingProbabilities(from: firstLogs, allowedRatings: ReviewRating.allCases),
            firstReviewDurations: averageDurationsByRating(from: firstLogs, allowedRatings: ReviewRating.allCases),
            recallRatingProbabilities: ratingProbabilities(from: laterLogs, allowedRatings: [.hard, .good, .easy]),
            reviewDurations: averageDurationsByRating(from: laterLogs, allowedRatings: ReviewRating.allCases)
        )
    }

    func simulateCost(
        desiredRetention: Double,
        parameters: Scheduler.Parameters,
        numberOfCards: Int,
        probabilitiesAndCosts: ProbabilitiesAndCosts
    ) -> Double {
        let utcCalendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let startDate = utcCalendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2025,
            month: 1,
            day: 1
        ))!
        let endDate = utcCalendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 1,
            day: 1
        ))!

        var rng = SeededGenerator(state: 42)
        let scheduler = scheduler(parameters: parameters.weights, targetRetention: desiredRetention)
        var simulationCost = 0.0

        for index in 0..<numberOfCards {
            let simulatedCardID = deterministicUUID(for: index)
            var card = Card(id: simulatedCardID, dueDate: startDate)
            var currentDate = startDate

            while currentDate < endDate {
                let rating: ReviewRating
                if currentDate == startDate {
                    rating = rng.choose(
                        from: ReviewRating.allCases,
                        weights: probabilitiesAndCosts.firstRatingProbabilities
                    )
                    simulationCost += probabilitiesAndCosts.firstReviewDurations[rating] ?? 0
                } else {
                    let recalled = rng.nextDouble() < desiredRetention
                    if recalled {
                        rating = rng.choose(
                            from: [.hard, .good, .easy],
                            weights: probabilitiesAndCosts.recallRatingProbabilities
                        )
                    } else {
                        rating = .again
                    }
                    simulationCost += probabilitiesAndCosts.reviewDurations[rating] ?? 0
                }

                card = (try? scheduler.review(card, rating: rating, at: currentDate, elapsed: nil, using: &rng).updatedCard) ?? card
                currentDate = card.dueDate
            }
        }

        let totalKnowledge = desiredRetention * Double(numberOfCards)
        return simulationCost / totalKnowledge
    }

    private func countOptimizableReviews() -> Int {
        var count = 0
        for history in histories {
            let reviews = Array(history.reviews.prefix(maximumSequenceLength))
            guard let firstReview = reviews.first else {
                continue
            }

            var card = Card(id: history.cardID, dueDate: firstReview.reviewedAt)
            for review in reviews {
                if let lastReviewedAt = card.lastReviewedAt,
                   dayDifference(from: lastReviewedAt, to: review.reviewedAt) > 0
                {
                    count += 1
                }
                card = (try? scheduler(parameters: configurationTemplate.parameters.weights, targetRetention: configurationTemplate.targetRetention)
                    .review(card, rating: review.rating, at: review.reviewedAt, elapsed: nil)
                    .updatedCard) ?? card
            }
        }
        return count
    }

    private func updateParameters(
        batch: TrainingBatch,
        weights: inout [Double],
        firstMoment: inout [Double],
        secondMoment: inout [Double],
        optimizationStep: Int,
        totalOptimizationSteps: Int
    ) {
        let gradients = approximateGradients(for: batch, weights: weights)
        let learningRate = cosineAnnealedLearningRate(step: optimizationStep - 1, totalSteps: totalOptimizationSteps)

        for index in weights.indices {
            let gradient = gradients[index].isFinite ? gradients[index] : 0
            firstMoment[index] = Self.adamBeta1 * firstMoment[index] + (1 - Self.adamBeta1) * gradient
            secondMoment[index] = Self.adamBeta2 * secondMoment[index] + (1 - Self.adamBeta2) * gradient * gradient

            let correctedFirstMoment = firstMoment[index] / (1 - pow(Self.adamBeta1, Double(optimizationStep)))
            let correctedSecondMoment = secondMoment[index] / (1 - pow(Self.adamBeta2, Double(optimizationStep)))

            weights[index] -= learningRate * correctedFirstMoment / (sqrt(correctedSecondMoment) + Self.adamEpsilon)
            weights[index] = clamp(weight: weights[index], at: index)
        }
    }

    private func approximateGradients(for batch: TrainingBatch, weights: [Double]) -> [Double] {
        var gradients = Array(repeating: 0.0, count: weights.count)

        for index in weights.indices {
            let delta = max(Self.gradientMinimumDelta, abs(weights[index]) * Self.gradientDeltaScale)
            let upperWeight = clamp(weight: weights[index] + delta, at: index)
            let lowerWeight = clamp(weight: weights[index] - delta, at: index)
            let denominator = upperWeight - lowerWeight
            guard denominator > 0 else {
                continue
            }

            var upperWeights = weights
            var lowerWeights = weights
            upperWeights[index] = upperWeight
            lowerWeights[index] = lowerWeight

            let upperLoss = batchLoss(for: batch, parameters: upperWeights)
            let lowerLoss = batchLoss(for: batch, parameters: lowerWeights)
            gradients[index] = (upperLoss - lowerLoss) / denominator
        }

        return gradients
    }

    private func batchLoss(for batch: TrainingBatch, parameters: [Double]) -> Double {
        let scheduler = scheduler(parameters: parameters, targetRetention: configurationTemplate.targetRetention)
        var cards = batch.initialCards
        var losses = [Double]()

        for event in batch.events {
            guard var card = cards[event.cardID] else {
                continue
            }

            let prediction = scheduler.retrievability(of: card, at: event.review.reviewedAt)
            if event.countsForLoss {
                losses.append(binaryCrossEntropy(prediction: prediction, target: event.review.recall))
            }

            card = (try? scheduler.review(card, rating: event.review.rating, at: event.review.reviewedAt, elapsed: nil).updatedCard) ?? card
            cards[event.cardID] = card
        }

        guard !losses.isEmpty else {
            return 0
        }
        return losses.reduce(0, +) / Double(losses.count)
    }

    private func cosineAnnealedLearningRate(step: Int, totalSteps: Int) -> Double {
        guard totalSteps > 0 else {
            return learningRate
        }
        let progress = min(max(Double(step) / Double(totalSteps), 0), 1)
        return learningRate * 0.5 * (1 + cos(.pi * progress))
    }

    private func scheduler(parameters: [Double], targetRetention: Double) -> Scheduler {
        let configuration = try! Scheduler.Configuration(
            parameters: parameterSet(from: parameters),
            targetRetention: targetRetention,
            learningStepDurations: configurationTemplate.learningStepDurations,
            relearningStepDurations: configurationTemplate.relearningStepDurations,
            maximumIntervalDays: configurationTemplate.maximumIntervalDays,
            fuzzingPolicy: .disabled
        )
        return Scheduler(configuration: configuration)
    }

    private func parameterSet(from weights: [Double]) -> Scheduler.Parameters {
        try! Scheduler.Parameters(weights: weights)
    }

    private func clamp(weight: Double, at index: Int) -> Double {
        let range = Self.parameterBounds[index]
        return min(max(weight, range.lowerBound), range.upperBound)
    }

    private func binaryCrossEntropy(prediction: Double, target: Double) -> Double {
        let clampedPrediction = min(max(prediction, 1e-12), 1 - 1e-12)
        return -(target * log(clampedPrediction) + (1 - target) * log(1 - clampedPrediction))
    }

    private func ratingProbabilities(
        from reviewLogs: [ReviewLog],
        allowedRatings: [ReviewRating]
    ) -> [ReviewRating: Double] {
        guard !reviewLogs.isEmpty else {
            return Dictionary(uniqueKeysWithValues: allowedRatings.map { ($0, 0) })
        }

        var counts = [ReviewRating: Int]()
        for rating in allowedRatings {
            counts[rating] = 0
        }
        for reviewLog in reviewLogs where allowedRatings.contains(reviewLog.rating) {
            counts[reviewLog.rating, default: 0] += 1
        }

        let total = counts.values.reduce(0, +)
        guard total > 0 else {
            let uniform = 1.0 / Double(allowedRatings.count)
            return Dictionary(uniqueKeysWithValues: allowedRatings.map { ($0, uniform) })
        }

        return Dictionary(uniqueKeysWithValues: allowedRatings.map {
            ($0, Double(counts[$0, default: 0]) / Double(total))
        })
    }

    private func averageDurationsByRating(
        from reviewLogs: [ReviewLog],
        allowedRatings: [ReviewRating]
    ) -> [ReviewRating: Double] {
        var durations = [ReviewRating: [Double]]()
        for reviewLog in reviewLogs where allowedRatings.contains(reviewLog.rating) {
            guard let elapsed = reviewLog.elapsed else {
                continue
            }
            durations[reviewLog.rating, default: []].append(elapsed.timeInterval * 1_000.0)
        }

        return Dictionary(uniqueKeysWithValues: allowedRatings.map { rating in
            let values = durations[rating, default: []]
            let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            return (rating, average)
        })
    }

    private func dayDifference(from earlier: Date, to later: Date) -> Int {
        Int(floor((later.timeIntervalSince1970 - earlier.timeIntervalSince1970) / 86_400.0))
    }

    private func deterministicUUID(for index: Int) -> UUID {
        let high = String(format: "%04X", index & 0xFFFF)
        let low = String(format: "%012llX", UInt64(index))
        return UUID(uuidString: "00000000-0000-0000-\(high)-\(low)")!
    }

    private static func makeHistories(from reviewLogs: [ReviewLog]) -> [ReviewHistory] {
        var grouped = [UUID: [HistoryReview]]()
        for reviewLog in reviewLogs {
            grouped[reviewLog.cardID, default: []].append(
                HistoryReview(
                    reviewedAt: reviewLog.reviewedAt,
                    rating: reviewLog.rating,
                    elapsed: reviewLog.elapsed,
                    recall: reviewLog.rating == .again ? 0 : 1
                )
            )
        }

        return grouped
            .map { cardID, reviews in
                ReviewHistory(
                    cardID: cardID,
                    reviews: reviews.sorted { $0.reviewedAt < $1.reviewedAt }
                )
            }
            .sorted { $0.cardID.uuidString < $1.cardID.uuidString }
    }
}

extension Optimizer {
    struct ProbabilitiesAndCosts {
        let firstRatingProbabilities: [ReviewRating: Double]
        let firstReviewDurations: [ReviewRating: Double]
        let recallRatingProbabilities: [ReviewRating: Double]
        let reviewDurations: [ReviewRating: Double]
    }

    private struct ReviewHistory: Sendable {
        let cardID: UUID
        let reviews: [HistoryReview]
    }

    private struct HistoryReview: Sendable {
        let reviewedAt: Date
        let rating: ReviewRating
        let elapsed: Duration?
        let recall: Double
    }

    private struct BatchEvent: Sendable {
        let review: HistoryReview
        let cardID: UUID
        let countsForLoss: Bool
    }

    private struct TrainingBatch: Sendable {
        let initialCards: [UUID: Card]
        let events: [BatchEvent]
    }

    private struct SeededGenerator: RandomNumberGenerator, Sendable {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func nextDouble() -> Double {
            Double(next()) / Double(UInt64.max)
        }

        mutating func choose(
            from values: [ReviewRating],
            weights: [ReviewRating: Double]
        ) -> ReviewRating {
            let totalWeight = max(values.reduce(0) { $0 + weights[$1, default: 0] }, .leastNonzeroMagnitude)
            let target = nextDouble() * totalWeight
            var cumulativeWeight = 0.0

            for value in values {
                cumulativeWeight += weights[value, default: 0]
                if target <= cumulativeWeight {
                    return value
                }
            }

            return values[values.index(before: values.endIndex)]
        }

        mutating func shuffle<T>(_ values: inout [T]) {
            guard values.count > 1 else {
                return
            }

            for index in stride(from: values.count - 1, through: 1, by: -1) {
                let offset = Int(next() % UInt64(index + 1))
                if offset != index {
                    values.swapAt(index, offset)
                }
            }
        }
    }
}
