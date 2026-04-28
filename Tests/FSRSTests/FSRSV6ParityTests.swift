//
//  FSRSV6ParityTests.swift
//  FSRS
//

import XCTest
@testable import FSRS

final class FSRSV6ParityTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testDefaultIntervalHistoryMatchesPythonAndRustReference() throws {
        let scheduler = FSRS(parameters: .init(enableFuzz: false))
        var card = FSRSDefaults().createEmptyCard()
        var reviewTime = calendar.date(
            from: DateComponents(year: 2022, month: 11, day: 29, hour: 12, minute: 30)
        )!

        let ratings: [Rating] = [
            .good, .good, .good, .good, .good, .good,
            .again, .again, .good, .good, .good, .good, .good,
        ]

        var intervalHistory: [Int] = []
        for rating in ratings {
            card = try scheduler.next(card: card, now: reviewTime, grade: rating).card
            intervalHistory.append(Int(card.scheduledDays))
            reviewTime = card.due
        }

        XCTAssertEqual(intervalHistory, [0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21])
    }
}
