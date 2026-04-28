import XCTest
@testable import FSRS

final class SerializationTests: XCTestCase {
    private func makeScheduler() -> Scheduler {
        Scheduler()
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    func test_card_codable_round_trip() throws {
        let original = try Card(
            dueDate: Date(timeIntervalSinceReferenceDate: 1_234),
            lastReviewedAt: Date(timeIntervalSinceReferenceDate: 1_200),
            state: .review(memory: MemoryState(stability: 12.3, difficulty: 4.5))
        )

        let copied = try decode(Card.self, from: encode(original))
        XCTAssertEqual(original, copied)
    }

    func test_review_log_codable_round_trip_with_duration() throws {
        let original = ReviewLog(
            cardID: UUID(),
            rating: .good,
            reviewedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            elapsed: .milliseconds(1500)
        )

        let copied = try decode(ReviewLog.self, from: encode(original))
        XCTAssertEqual(original, copied)
    }

    func test_scheduler_codable_round_trip() throws {
        let original = Scheduler(
            configuration: try Scheduler.Configuration(
                parameters: .default,
                targetRetention: 0.92,
                learningStepDurations: [.seconds(60), .seconds(600)],
                relearningStepDurations: [.seconds(600)],
                maximumIntervalDays: 3650,
                fuzzingPolicy: .disabled
            )
        )

        let copied = try decode(Scheduler.self, from: encode(original))
        XCTAssertEqual(original, copied)
    }

    func test_review_result_codable_round_trip() throws {
        let scheduler = makeScheduler()
        let result = try scheduler.review(
            Card(),
            rating: .good,
            at: Date(timeIntervalSinceReferenceDate: 500),
            elapsed: .seconds(12)
        )

        let copied = try decode(ReviewResult.self, from: encode(result))
        XCTAssertEqual(result, copied)
    }

    func test_json_shape_uses_swift_keys_and_string_enums() throws {
        let card = try Card(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            dueDate: Date(timeIntervalSinceReferenceDate: 1_234),
            lastReviewedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            state: .learning(step: 1, memory: MemoryState(stability: 2.5, difficulty: 6.0))
        )
        let reviewLog = ReviewLog(
            cardID: card.id,
            rating: .good,
            reviewedAt: card.dueDate,
            elapsed: .milliseconds(250)
        )

        let cardJSON = String(decoding: try encode(card), as: UTF8.self)
        let reviewLogJSON = String(decoding: try encode(reviewLog), as: UTF8.self)

        XCTAssertTrue(cardJSON.contains("\"dueDate\""))
        XCTAssertTrue(cardJSON.contains("\"lastReviewedAt\""))
        XCTAssertTrue(cardJSON.contains("\"type\":\"learning\""))
        XCTAssertFalse(cardJSON.contains("\"lastReview\""))
        XCTAssertFalse(cardJSON.contains("\"state\":2"))

        XCTAssertTrue(reviewLogJSON.contains("\"reviewedAt\""))
        XCTAssertTrue(reviewLogJSON.contains("\"rating\":\"good\""))
        XCTAssertTrue(reviewLogJSON.contains("\"elapsed\""))
        XCTAssertFalse(reviewLogJSON.contains("\"reviewDate\""))
        XCTAssertFalse(reviewLogJSON.contains("\"rating\":3"))
    }

    func test_invalid_new_card_payload_is_rejected() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "dueDate": 1234,
          "lastReviewedAt": 1200,
          "state": {
            "type": "new"
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try decode(Card.self, from: payload)) { error in
            XCTAssertEqual(error as? FSRSError, .invalidCardState(.newCardCannotHaveLastReviewedAt))
        }
    }

    func test_invalid_review_card_payload_is_rejected() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "dueDate": 1234,
          "state": {
            "type": "review",
            "memory": {
              "stability": 5.0,
              "difficulty": 4.0
            }
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try decode(Card.self, from: payload)) { error in
            XCTAssertEqual(error as? FSRSError, .invalidCardState(.reviewedCardRequiresLastReviewedAt))
        }
    }
}
