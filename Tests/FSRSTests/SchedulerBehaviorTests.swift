import XCTest
@testable import FSRS

final class SchedulerBehaviorTests: XCTestCase {
    private let referenceRatings: [ReviewRating] = [
        .good, .good, .good, .good, .good, .good,
        .again, .again, .good, .good, .good, .good, .good,
    ]

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }

    private func makeScheduler(
        parameters: Scheduler.Parameters = .default,
        targetRetention: Double = 0.9,
        learningStepDurations: [Duration] = [.seconds(60), .seconds(600)],
        relearningStepDurations: [Duration] = [.seconds(600)],
        maximumIntervalDays: Int = 36500,
        fuzzingPolicy: Scheduler.FuzzingPolicy = .enabled
    ) -> Scheduler {
        let configuration = try! Scheduler.Configuration(
            parameters: parameters,
            targetRetention: targetRetention,
            learningStepDurations: learningStepDurations,
            relearningStepDurations: relearningStepDurations,
            maximumIntervalDays: maximumIntervalDays,
            fuzzingPolicy: fuzzingPolicy
        )
        return Scheduler(configuration: configuration)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0)!,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )!
    }

    func test_review_interval_history_matches_reference() throws {
        let scheduler = makeScheduler(fuzzingPolicy: .disabled)
        var card = Card()
        var reviewedAt = utcDate(2022, 11, 29, 12, 30)
        var intervalHistory = [Int]()

        for rating in referenceRatings {
            let result = try scheduler.review(card, rating: rating, at: reviewedAt)
            card = result.updatedCard
            intervalHistory.append(Int(card.dueDate.timeIntervalSince(card.lastReviewedAt!) / 86_400))
            reviewedAt = card.dueDate
        }

        XCTAssertEqual(intervalHistory, [0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21])
    }

    func test_repeated_correct_reviews_drive_difficulty_to_floor() throws {
        let scheduler = makeScheduler(fuzzingPolicy: .disabled)
        var card = Card()
        let reviewDates = (0..<10).map { utcDate(2022, 11, 29, 12, 30, $0) }

        for reviewedAt in reviewDates {
            card = try scheduler.review(card, rating: .easy, at: reviewedAt).updatedCard
        }

        guard case let .review(memory) = card.state else {
            return XCTFail("Expected review state")
        }
        XCTAssertEqual(memory.difficulty, 1.0)
    }

    func test_memo_state_matches_reference_values() throws {
        let scheduler = makeScheduler()
        let ratings: [ReviewRating] = [.again, .good, .good, .good, .good, .good]
        let intervals = [0, 0, 1, 3, 8, 21]

        var card = Card()
        var reviewedAt = utcDate(2022, 11, 29, 12, 30)

        for (rating, interval) in zip(ratings, intervals) {
            reviewedAt = reviewedAt.addingTimeInterval(Double(interval) * 86_400)
            card = try scheduler.review(card, rating: rating, at: reviewedAt).updatedCard
        }

        guard case let .review(memory) = card.state else {
            return XCTFail("Expected review state")
        }
        XCTAssertEqual(memory.stability, 53.62691, accuracy: 1e-4)
        XCTAssertEqual(memory.difficulty, 6.3574867, accuracy: 1e-4)
    }

    func test_new_card_state_is_explicit() {
        let card = Card()
        XCTAssertEqual(card.state, .new)
        XCTAssertNil(card.lastReviewedAt)
    }

    func test_review_promotes_new_card_into_learning() throws {
        let scheduler = makeScheduler()
        let result = try scheduler.review(Card(), rating: .good, at: utcDate(2022, 11, 29, 12, 30))

        guard case let .learning(step, memory) = result.updatedCard.state else {
            return XCTFail("Expected learning state")
        }

        XCTAssertEqual(step, 1)
        XCTAssertNotNil(result.updatedCard.lastReviewedAt)
        XCTAssertGreaterThan(memory.stability, 0)
    }

    func test_retrievability_for_new_card_is_zero() {
        let scheduler = makeScheduler()
        XCTAssertEqual(scheduler.retrievability(of: Card()), 0)
    }

    func test_review_and_relearning_state_flow() throws {
        let scheduler = makeScheduler(fuzzingPolicy: .disabled)
        var card = Card()

        card = try scheduler.review(card, rating: .good, at: card.dueDate).updatedCard
        card = try scheduler.review(card, rating: .good, at: card.dueDate).updatedCard
        guard case .review = card.state else {
            return XCTFail("Expected review state")
        }

        card = try scheduler.review(card, rating: .again, at: card.dueDate).updatedCard
        guard case let .relearning(step, _) = card.state else {
            return XCTFail("Expected relearning state")
        }
        XCTAssertEqual(step, 0)
    }

    func test_learning_step_durations_follow_configuration() throws {
        let scheduler = makeScheduler()
        let createdAt = Date()
        var card = Card(dueDate: createdAt)

        card = try scheduler.review(card, rating: .good, at: card.dueDate).updatedCard
        guard case let .learning(step, _) = card.state else {
            return XCTFail("Expected learning state")
        }
        XCTAssertEqual(step, 1)
        XCTAssertEqual(card.dueDate.timeIntervalSince(createdAt), 600, accuracy: 1)

        card = try scheduler.review(card, rating: .good, at: card.dueDate).updatedCard
        guard case .review = card.state else {
            return XCTFail("Expected review state")
        }
        XCTAssertGreaterThanOrEqual(card.dueDate.timeIntervalSince(createdAt) / 3600, 24)
    }

    func test_no_learning_steps_immediately_graduates_card() throws {
        let scheduler = makeScheduler(learningStepDurations: [])
        let updatedCard = try scheduler.review(Card(), rating: .again, at: Date()).updatedCard

        guard case .review = updatedCard.state else {
            return XCTFail("Expected review state")
        }
    }

    func test_no_relearning_steps_skips_relearning_state() throws {
        let scheduler = makeScheduler(relearningStepDurations: [])
        var card = Card()
        card = try scheduler.review(card, rating: .good, at: Date()).updatedCard
        card = try scheduler.review(card, rating: .good, at: card.dueDate).updatedCard
        card = try scheduler.review(card, rating: .again, at: card.dueDate).updatedCard

        guard case .review = card.state else {
            return XCTFail("Expected review state")
        }
    }

    func test_maximum_interval_is_respected() throws {
        let scheduler = makeScheduler(maximumIntervalDays: 100)
        var card = Card()

        for rating in [ReviewRating.easy, .good, .easy, .good] {
            card = try scheduler.review(card, rating: rating, at: card.dueDate).updatedCard
            XCTAssertLessThanOrEqual(
                Int(card.dueDate.timeIntervalSince(card.lastReviewedAt!) / 86_400),
                scheduler.configuration.maximumIntervalDays
            )
        }
    }

    func test_unique_card_ids_use_uuid_generation() {
        let ids = (0..<1000).map { _ in Card().id }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func test_stability_lower_bound_is_preserved() throws {
        let scheduler = makeScheduler()
        var card = Card()

        for _ in 0..<1000 {
            card = try scheduler.review(
                card,
                rating: .again,
                at: card.dueDate.addingTimeInterval(86_400)
            ).updatedCard

            guard let memory = card.state.memory else {
                continue
            }
            XCTAssertGreaterThanOrEqual(memory.stability, 0.001)
        }
    }

    func test_deterministic_fuzz_uses_seeded_generator() throws {
        let scheduler = makeScheduler()
        var firstGenerator = SeededGenerator(state: 42)
        var secondGenerator = SeededGenerator(state: 42)

        var firstCard = Card()
        var secondCard = Card()

        firstCard = try scheduler.review(firstCard, rating: .good, at: firstCard.dueDate, using: &firstGenerator).updatedCard
        firstCard = try scheduler.review(firstCard, rating: .good, at: firstCard.dueDate, using: &firstGenerator).updatedCard
        let firstPreviousDue = firstCard.dueDate
        firstCard = try scheduler.review(firstCard, rating: .good, at: firstCard.dueDate, using: &firstGenerator).updatedCard

        secondCard = try scheduler.review(secondCard, rating: .good, at: secondCard.dueDate, using: &secondGenerator).updatedCard
        secondCard = try scheduler.review(secondCard, rating: .good, at: secondCard.dueDate, using: &secondGenerator).updatedCard
        let secondPreviousDue = secondCard.dueDate
        secondCard = try scheduler.review(secondCard, rating: .good, at: secondCard.dueDate, using: &secondGenerator).updatedCard

        XCTAssertEqual(firstCard.dueDate.timeIntervalSince(firstPreviousDue), secondCard.dueDate.timeIntervalSince(secondPreviousDue))
    }

    func test_replay_respects_matching_card_ids() throws {
        let scheduler = makeScheduler(fuzzingPolicy: .disabled)
        var card = Card()
        let first = try scheduler.review(card, rating: .good, at: utcDate(2022, 11, 29, 12, 30))
        card = first.updatedCard
        let second = try scheduler.review(card, rating: .good, at: card.dueDate)

        let replayed = try scheduler.replay([first.reviewLog, second.reviewLog], for: Card(id: card.id, dueDate: first.updatedCard.dueDate))
        XCTAssertEqual(second.updatedCard.state, replayed.state)
    }

    func test_replay_rejects_mismatched_card_ids() throws {
        let scheduler = makeScheduler(fuzzingPolicy: .disabled)
        let card = Card()
        let reviewLog = try scheduler.review(card, rating: .good, at: Date()).reviewLog
        let mismatchedLog = ReviewLog(cardID: UUID(), rating: reviewLog.rating, reviewedAt: reviewLog.reviewedAt)

        XCTAssertThrowsError(try scheduler.replay([mismatchedLog], for: card)) { error in
            XCTAssertEqual(error as? FSRSError, .mismatchedReviewLogCardID(expected: card.id, actual: mismatchedLog.cardID))
        }
    }

    func test_parameter_validation_uses_typed_errors() {
        XCTAssertNoThrow(try Scheduler.Parameters(weights: Scheduler.Parameters.default.weights))

        XCTAssertThrowsError(try Scheduler.Parameters(weights: [])) { error in
            XCTAssertEqual(
                error as? FSRSError,
                .invalidParameters([.incorrectCount(expected: 21, actual: 0)])
            )
        }

        var invalidWeights = Scheduler.Parameters.default.weights
        invalidWeights[6] = 100
        XCTAssertThrowsError(try Scheduler.Parameters(weights: invalidWeights)) { error in
            XCTAssertEqual(
                error as? FSRSError,
                .invalidParameters([.outOfRange(index: 6, value: 100, allowed: 0.001...4.0)])
            )
        }
    }

    func test_configuration_validation_uses_typed_errors() {
        XCTAssertThrowsError(
            try Scheduler.Configuration(targetRetention: 1.0)
        ) { error in
            XCTAssertEqual(error as? FSRSError, .invalidConfiguration(.invalidTargetRetention(1.0)))
        }

        XCTAssertThrowsError(
            try Scheduler.Configuration(learningStepDurations: [.seconds(-1)])
        ) { error in
            XCTAssertEqual(error as? FSRSError, .invalidConfiguration(.invalidLearningStepDuration(.seconds(-1))))
        }

        XCTAssertThrowsError(
            try Scheduler.Configuration(relearningStepDurations: [.seconds(-1)])
        ) { error in
            XCTAssertEqual(error as? FSRSError, .invalidConfiguration(.invalidRelearningStepDuration(.seconds(-1))))
        }

        XCTAssertThrowsError(
            try Scheduler.Configuration(maximumIntervalDays: 0)
        ) { error in
            XCTAssertEqual(error as? FSRSError, .invalidConfiguration(.invalidMaximumIntervalDays(0)))
        }
    }
}
