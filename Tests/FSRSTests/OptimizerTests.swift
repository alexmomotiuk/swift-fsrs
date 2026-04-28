import Foundation
import XCTest
@testable import FSRS

final class OptimizerTests: XCTestCase {
    func test_zero_review_logs_return_starting_parameters() {
        let optimizer = Optimizer(reviewLogs: [])

        let parameters = optimizer.computeOptimalParameters()

        XCTAssertEqual(parameters, .default)
    }

    func test_few_review_logs_return_starting_parameters() {
        let optimizer = Optimizer(reviewLogs: makeSyntheticReviewLogs(cards: 8, reviewsPerCard: 6))

        let parameters = optimizer.computeOptimalParameters()

        XCTAssertEqual(parameters, .default)
    }

    func test_unordered_review_logs_produce_same_optimal_parameters() {
        let reviewLogs = makeSyntheticReviewLogs(cards: 24, reviewsPerCard: 12)
        var shuffledReviewLogs = reviewLogs
        shuffledReviewLogs.reverse()

        let optimizer1 = Optimizer(reviewLogs: reviewLogs, trainingEpochs: 1, miniBatchSize: 32)
        let optimizer2 = Optimizer(reviewLogs: shuffledReviewLogs, trainingEpochs: 1, miniBatchSize: 32)

        let parameters1 = optimizer1.computeOptimalParameters()
        let parameters2 = optimizer2.computeOptimalParameters()

        XCTAssertEqual(parameters1, parameters2)
    }

    func test_compute_optimal_parameters_is_deterministic_and_changes_weights() {
        let reviewLogs = makeSyntheticReviewLogs(cards: 24, reviewsPerCard: 12)
        let optimizer = Optimizer(reviewLogs: reviewLogs, trainingEpochs: 1, miniBatchSize: 32)

        let first = optimizer.computeOptimalParameters()
        let second = optimizer.computeOptimalParameters()

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, .default)
    }

    func test_compute_optimal_retention_requires_durations() {
        let reviewLogs = (0..<600).map { index in
            ReviewLog(
                cardID: UUID(),
                rating: index.isMultiple(of: 4) ? .again : .good,
                reviewedAt: Date(timeIntervalSince1970: Double(index * 86_400)),
                elapsed: nil
            )
        }
        let optimizer = Optimizer(reviewLogs: reviewLogs)

        XCTAssertThrowsError(try optimizer.computeOptimalRetention(parameters: .default)) { error in
            XCTAssertEqual(error as? OptimizerError, .missingReviewDuration(cardID: reviewLogs[0].cardID))
        }
    }

    func test_compute_optimal_retention_is_deterministic_for_fixture_review_logs() throws {
        let reviewLogs = try fixtureReviewLogs()
        let optimizer = Optimizer(reviewLogs: reviewLogs)

        let first = try optimizer.computeOptimalRetention(parameters: .default)
        let second = try optimizer.computeOptimalRetention(parameters: .default)

        XCTAssertEqual(first, second)
        XCTAssertTrue([0.7, 0.75, 0.8, 0.85, 0.9, 0.95].contains(first))
    }

    private func makeSyntheticReviewLogs(cards: Int, reviewsPerCard: Int) -> [ReviewLog] {
        let baseWeights = [
            0.12, 1.3, 2.39, 8.29, 6.68,
            0.45, 3.07, 0.05, 1.65, 0.14,
            0.63, 1.61, 0.012, 0.34, 1.88,
            0.85, 1.87, 0.67, 0.20, 0.22,
            0.46,
        ]
        let parameters = try! Scheduler.Parameters(weights: baseWeights)
        let configuration = try! Scheduler.Configuration(parameters: parameters, fuzzingPolicy: .disabled)
        let scheduler = Scheduler(configuration: configuration)
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let ratings: [ReviewRating] = [.good, .easy, .good, .hard, .good, .easy, .good, .again, .good, .easy, .good, .hard]

        var reviewLogs = [ReviewLog]()
        for cardIndex in 0..<cards {
            var card = Card(
                id: deterministicUUID(for: cardIndex),
                dueDate: startDate.addingTimeInterval(Double(cardIndex) * 60)
            )
            var reviewedAt = startDate.addingTimeInterval(Double(cardIndex) * 60)

            for reviewIndex in 0..<reviewsPerCard {
                let rating = ratings[reviewIndex % ratings.count]
                let result = try! scheduler.review(
                    card,
                    rating: rating,
                    at: reviewedAt,
                    elapsed: .milliseconds(Int64(1_200 + reviewIndex * 75))
                )
                reviewLogs.append(result.reviewLog)
                card = result.updatedCard
                reviewedAt = card.dueDate
            }
        }

        return reviewLogs
    }

    private func fixtureReviewLogs() throws -> [ReviewLog] {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("py-fsrs/tests/review_logs_josh_1711744352250_to_1728234780857.csv")

        let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline)
        let dateFormatters = [
            ISO8601DateFormatter(),
            ISO8601DateFormatter(),
        ]
        dateFormatters[0].formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dateFormatters[1].formatOptions = [.withInternetDateTime]

        return try lines.dropFirst().map { line in
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            let rawCardID = String(columns[0])
            let rawRating = String(columns[1])
            let rawDate = String(columns[2])
            let rawDuration = String(columns[3])

            guard let cardNumber = UInt64(rawCardID) else {
                throw NSError(domain: "OptimizerTests", code: 1)
            }
            let date = dateFormatters.lazy.compactMap { $0.date(from: rawDate) }.first
            guard let date else {
                throw NSError(domain: "OptimizerTests", code: 2)
            }
            guard let duration = Int64(rawDuration) else {
                throw NSError(domain: "OptimizerTests", code: 3)
            }

            let rating: ReviewRating
            switch rawRating {
            case "1": rating = .again
            case "2": rating = .hard
            case "3": rating = .good
            case "4": rating = .easy
            default: throw NSError(domain: "OptimizerTests", code: 4)
            }

            return ReviewLog(
                cardID: deterministicUUID(for: cardNumber),
                rating: rating,
                reviewedAt: date,
                elapsed: .milliseconds(duration)
            )
        }
    }

    private func deterministicUUID(for value: Int) -> UUID {
        deterministicUUID(for: UInt64(value))
    }

    private func deterministicUUID(for value: UInt64) -> UUID {
        let paddedHex = String(format: "%016llX", value)
        let group4 = String(paddedHex.prefix(4))
        let group5 = String(paddedHex.suffix(12))
        return UUID(uuidString: "00000000-0000-0000-\(group4)-\(group5)")!
    }
}
