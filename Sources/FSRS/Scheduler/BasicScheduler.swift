//
//  BasicScheduler.swift
//
//  Created by nkq on 10/14/24.
//

import Foundation

class BasicScheduler: AbstractScheduler {
    private var learningSteps: [Double] { algorithm.params.learningSteps }
    private var relearningSteps: [Double] { algorithm.params.relearningSteps }

    override func newState(grade: Rating) -> RecordLogItem {
        if let item = next[grade] { return item }
        var next = current.newCard
        next.difficulty = algorithm.initDifficulty(grade)
        next.stability = algorithm.initStability(g: grade)
        applyLearningTransition(
            to: &next,
            grade: grade,
            currentStep: 0,
            steps: learningSteps,
            learningState: .learning
        )
        return .init(card: next, log: buildLog(rating: grade))
    }

    override func learningState(grade: Rating) -> RecordLogItem {
        if let item = next[grade] { return item }
        var next = current.newCard
        let interval = current.elapsedDays
        next.difficulty = algorithm.nextDifficulty(d: last.difficulty, g: grade)
        next.stability = algorithm.nextShortTermStability(s: last.stability, g: grade)
        applyLearningTransition(
            to: &next,
            grade: grade,
            currentStep: last.step ?? 0,
            steps: last.state == .relearning ? relearningSteps : learningSteps,
            learningState: last.state == .relearning ? .relearning : .learning,
            elapsedDays: interval
        )
        return .init(card: next, log: buildLog(rating: grade))
    }

    override func reviewState(grade: Rating) -> RecordLogItem {
        if let item = next[grade] { return item }
        let interval = current.elapsedDays
        let retrievability = algorithm.forgettingCurve(
            elapsedDays: interval, stability: last.stability
        )
        let nextArray = Array(repeating: current.newCard, count: 4)
        var nextAgain = nextArray[0]
        var nextHard = nextArray[1]
        var nextGood = nextArray[2]
        var nextEasy = nextArray[3]
        
        nextDs(
            &nextAgain, &nextHard, &nextGood, &nextEasy,
            difficulty: last.difficulty,
            stability: last.stability,
            retrievability: retrievability
        )
        
        nextInterval(&nextAgain, &nextHard, &nextGood, &nextEasy, interval: interval)
        nextState(&nextAgain, &nextHard, &nextGood, &nextEasy)
        
        nextAgain.lapses += 1
        
        let itemAgain = RecordLogItem(
            card: nextAgain,
            log: buildLog(rating: .again)
        )
        let itemHard = RecordLogItem(
            card: nextHard,
            log: buildLog(rating: .hard)
        )
        let itemGood = RecordLogItem(
            card: nextGood,
            log: buildLog(rating: .good)
        )
        let itemEasy = RecordLogItem(
            card: nextEasy,
            log: buildLog(rating: .easy)
        )
        
        next[.again] = itemAgain
        next[.hard] = itemHard
        next[.good] = itemGood
        next[.easy] = itemEasy

        return next[grade]!
    }

    private func nextDs(
        _ nextAgain: inout Card,
        _ nextHard: inout Card,
        _ nextGood: inout Card,
        _ nextEasy: inout Card,
        difficulty: Double,
        stability: Double,
        retrievability: Double
    ) {
        nextAgain.difficulty = algorithm.nextDifficulty(d: difficulty, g: .again)
        nextAgain.stability = algorithm.nextForgetStability(
            d: difficulty,
            s: stability,
            r: retrievability
        )
        
        nextHard.difficulty = algorithm.nextDifficulty(d: difficulty, g: .hard)
        nextHard.stability = algorithm.nextRecallStability(
            d: difficulty, s: stability, r: retrievability, g: .hard
        )
        
        nextGood.difficulty = algorithm.nextDifficulty(d: difficulty, g: .good)
        nextGood.stability = algorithm.nextRecallStability(
            d: difficulty, s: stability, r: retrievability, g: .good
        )
        
        nextEasy.difficulty = algorithm.nextDifficulty(d: difficulty, g: .easy)
        nextEasy.stability = algorithm.nextRecallStability(
            d: difficulty, s: stability, r: retrievability, g: .easy
        )
    }

    private func nextInterval(
        _ nextAgain: inout Card,
        _ nextHard: inout Card,
        _ nextGood: inout Card,
        _ nextEasy: inout Card,
        interval: Double
    ) {
        var hardInterval = algorithm.nextInterval(
            s: nextHard.stability, elapsedDays: interval
        )
        var goodInterval = algorithm.nextInterval(
            s: nextGood.stability, elapsedDays: interval
        )
        hardInterval = min(hardInterval, goodInterval)
        goodInterval = max(goodInterval, hardInterval + 1)
        let easyInteval = max(
            algorithm.nextInterval(s: nextEasy.stability, elapsedDays: interval),
            goodInterval + 1
        )
        if relearningSteps.isEmpty {
            let relearningInterval = min(
                algorithm.nextInterval(s: nextAgain.stability, elapsedDays: interval),
                hardInterval
            )
            nextAgain.scheduledDays = Double(relearningInterval)
            nextAgain.due = Date.dateScheduler(
                now: reviewTime,
                t: Double(relearningInterval),
                unit: .days
            )
        } else {
            nextAgain.scheduledDays = 0
            nextAgain.due = Date.dateScheduler(now: reviewTime, t: relearningSteps[0])
        }
        
        nextHard.scheduledDays = Double(hardInterval)
        nextHard.due = Date.dateScheduler(now: reviewTime, t: Double(hardInterval), unit: .days)
        
        nextGood.scheduledDays = Double(goodInterval)
        nextGood.due = Date.dateScheduler(now: reviewTime, t: Double(goodInterval), unit: .days)
        
        nextEasy.scheduledDays = Double(easyInteval)
        nextEasy.due = Date.dateScheduler(now: reviewTime, t: Double(easyInteval), unit: .days)
    }

    private func nextState(
        _ nextAgain: inout Card,
        _ nextHard: inout Card,
        _ nextGood: inout Card,
        _ nextEasy: inout Card
    ) {
        nextAgain.state = relearningSteps.isEmpty ? .review : .relearning
        nextAgain.step = relearningSteps.isEmpty ? nil : 0
        nextHard.state = .review
        nextHard.step = nil
        nextGood.state = .review
        nextGood.step = nil
        nextEasy.state = .review
        nextEasy.step = nil
    }

    private func applyLearningTransition(
        to card: inout Card,
        grade: Rating,
        currentStep: Int,
        steps: [Double],
        learningState: CardState,
        elapsedDays: Double = 0
    ) {
        if steps.isEmpty || (currentStep >= steps.count && [.hard, .good, .easy].contains(grade)) {
            graduate(&card, elapsedDays: elapsedDays)
            return
        }

        switch grade {
        case .again:
            scheduleShortTerm(&card, minutes: steps[0], state: learningState, step: 0)
        case .hard:
            let minutes: Double
            if currentStep == 0 && steps.count == 1 {
                minutes = steps[0] * 1.5
            } else if currentStep == 0 && steps.count >= 2 {
                minutes = (steps[0] + steps[1]) / 2.0
            } else {
                minutes = steps[min(currentStep, steps.count - 1)]
            }
            scheduleShortTerm(
                &card,
                minutes: minutes,
                state: learningState,
                step: min(currentStep, max(steps.count - 1, 0))
            )
        case .good:
            if currentStep + 1 == steps.count {
                graduate(&card, elapsedDays: elapsedDays)
            } else {
                let nextStep = min(currentStep + 1, steps.count - 1)
                scheduleShortTerm(
                    &card,
                    minutes: steps[nextStep],
                    state: learningState,
                    step: nextStep
                )
            }
        case .easy:
            graduate(&card, elapsedDays: elapsedDays)
        case .manual:
            break
        }
    }

    private func scheduleShortTerm(
        _ card: inout Card,
        minutes: Double,
        state: CardState,
        step: Int
    ) {
        card.scheduledDays = 0
        card.due = Date.dateScheduler(now: reviewTime, t: minutes)
        card.state = state
        card.step = step
    }

    private func graduate(_ card: inout Card, elapsedDays: Double) {
        let interval = algorithm.nextInterval(
            s: card.stability,
            elapsedDays: elapsedDays
        )
        card.scheduledDays = Double(interval)
        card.due = Date.dateScheduler(now: reviewTime, t: Double(interval), unit: .days)
        card.state = .review
        card.step = nil
    }
}
