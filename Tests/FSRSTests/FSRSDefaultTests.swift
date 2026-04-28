//
//  FSRSDefaultTests.swift
//  FSRS
//
//  Created by nkq on 10/19/24.
//


import XCTest
@testable import FSRS


class YourTestClass: XCTestCase {

    func testDefaultParams() {
        let expectedW = [
            0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722,
            0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425,
            0.0912, 0.0658, 0.1542,
        ]
        let defaults = FSRSDefaults()
        XCTAssertEqual(defaults.defaultRequestRetention, 0.9)
        XCTAssertEqual(defaults.defaultMaximumInterval, 36500)
        XCTAssertEqual(defaults.defaultEnableFuzz, false)
        XCTAssertEqual(defaults.defaultW.count, expectedW.count)
        XCTAssertEqual(defaults.defaultW, expectedW)

        let params = defaults.generatorParameters()
        
        XCTAssertEqual(params.requestRetention, defaults.defaultRequestRetention)
        XCTAssertEqual(params.maximumInterval, defaults.defaultMaximumInterval)
        XCTAssertEqual(params.w, expectedW)
        XCTAssertEqual(params.enableFuzz, defaults.defaultEnableFuzz)
        
        let params2 = defaults.generatorParameters(props: .init(w: [
            0.4, 0.6, 2.4, 5.8, 4.93, 0.94, 0.86, 0.01, 1.49, 0.14, 0.94, 2.18,
            0.05, 0.34, 1.26, 0.29, 2.61,
        ]))
        
        XCTAssertEqual(params2.w, [
            0.4, 0.6, 2.4, 5.8, 6.81, 0.44675014, 1.36, 0.01, 1.49, 0.14, 0.94, 2.18,
            0.05, 0.34, 1.26, 0.29, 2.61, 0.0, 0.0, 0.0, 0.5,
        ])
        
        var w = Array(repeating: 0.0, count: 21)
        var paramsClamp = defaults.generatorParameters(props: .init(w: w))
        let w_min = FSRSDefaults.CLAMP_PARAMETERS.map({ $0[0] })
        XCTAssertEqual(paramsClamp.w, w_min)
        
        w = Array(repeating: .infinity, count: 21)
        paramsClamp = defaults.generatorParameters(props: .init(w: w))
        let w_max = FSRSDefaults.CLAMP_PARAMETERS.map({ $0[1] })
        XCTAssertEqual(paramsClamp.w, w_max)
    }
    
    func testDefaultCard() {
        let times = [Date(), Date(timeIntervalSince1970: 1696291200)] // Replace with the appropriate timestamp
        for now in times {
            let card = FSRSDefaults().createEmptyCard(now: now)
            XCTAssertEqual(card.due, now)
            XCTAssertEqual(card.stability, 0)
            XCTAssertEqual(card.difficulty, 0)
            XCTAssertEqual(card.elapsedDays, 0)
            XCTAssertEqual(card.scheduledDays, 0)
            XCTAssertEqual(card.reps, 0)
            XCTAssertEqual(card.lapses, 0)
            XCTAssertEqual(card.state.rawValue, 0)
        }
    }
}
