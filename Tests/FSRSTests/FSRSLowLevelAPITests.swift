import XCTest
@testable import FSRS

final class FSRSLowLevelAPITests: XCTestCase {
    private var fsrs: FSRS!
    private var now: Date!

    override func setUp() {
        super.setUp()
        fsrs = FSRS(parameters: .init())
        now = Date(timeIntervalSince1970: 1_730_419_200)
    }

    func testConfigurableLearningAndRelearningStepsDriveScheduling() throws {
        let configured = FSRS(parameters: .init(
            learningSteps: [2, 20],
            relearningSteps: [30]
        ))

        let newCard = FSRSDefaults().createEmptyCard(now: now)
        let firstGood = try configured.next(card: newCard, now: now, grade: .good).card
        XCTAssertEqual(firstGood.state, .learning)
        XCTAssertEqual(firstGood.step, 1)
        XCTAssertEqual(firstGood.scheduledDays, 0)
        XCTAssertEqual(firstGood.due.timeIntervalSince1970, now.timeIntervalSince1970 + 20 * 60)

        let graduated = try configured.next(card: firstGood, now: firstGood.due, grade: .good).card
        XCTAssertEqual(graduated.state, .review)
        XCTAssertNil(graduated.step)

        let lapsed = try configured.next(card: graduated, now: graduated.due, grade: .again).card
        XCTAssertEqual(lapsed.state, .relearning)
        XCTAssertEqual(lapsed.step, 0)
        XCTAssertEqual(lapsed.due.timeIntervalSince1970, graduated.due.timeIntervalSince1970 + 30 * 60)
    }

    func testMemoryStateReplayAndHistory() throws {
        let reviews = [
            FSRSReview(rating: .again, deltaT: 0),
            FSRSReview(rating: .good, deltaT: 0),
            FSRSReview(rating: .good, deltaT: 1),
        ]

        let history = try fsrs.historicalMemoryStates(reviews: reviews)
        XCTAssertEqual(history.count, reviews.count)

        let replayed = try fsrs.memoryState(reviews: reviews)
        XCTAssertEqual(replayed, history.last)

        let nextStates = try fsrs.nextStates(memoryState: history[1], elapsedDays: 1)
        XCTAssertEqual(nextStates.good.memory, replayed)
        XCTAssertGreaterThan(nextStates.easy.interval, nextStates.good.interval)
        XCTAssertGreaterThan(nextStates.good.interval, nextStates.again.interval)
    }

    func testNextIntervalForNewCardUsesInitialStability() throws {
        let fromAPI = try fsrs.nextInterval(
            stability: nil,
            desiredRetention: 0.9,
            rating: .good
        )
        let fromState = try fsrs.nextInterval(
            stability: fsrs.nextState(memoryState: nil, t: 0, g: .good).stability,
            desiredRetention: 0.9,
            rating: .good
        )

        XCTAssertEqual(fromAPI, fromState)
    }

    func testMemoryStateFromSM2ReturnsFiniteBoundedValues() throws {
        let state = try fsrs.memoryStateFromSM2(
            easeFactor: 2.5,
            interval: 10,
            sm2Retention: 0.9
        )

        XCTAssertTrue(state.stability.isFinite)
        XCTAssertTrue(state.difficulty.isFinite)
        XCTAssertGreaterThanOrEqual(state.stability, 0.001)
        XCTAssertGreaterThanOrEqual(state.difficulty, 1.0)
        XCTAssertLessThanOrEqual(state.difficulty, 10.0)
    }

    func testCardNormalizesStepMetadata() {
        XCTAssertNil(Card(state: .review).step)
        XCTAssertEqual(Card(state: .learning).step, 0)
        XCTAssertEqual(Card(state: .relearning, step: 2).step, 2)
    }
}
