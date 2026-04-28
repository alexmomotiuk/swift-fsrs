A pure Swift implementation of FSRS.

`swift-fsrs` keeps the current scheduler math and defaults from modern FSRS,
but exposes them through a Swift-native API built around value types:

- `Card` uses `dueDate`, `lastReviewedAt`, and a typed `CardState`
- `ReviewLog` stores `reviewedAt` and optional `Duration`-based `elapsed`
- `Scheduler.Configuration` groups retention, step durations, interval limits,
  parameter weights, and fuzzing policy
- `Optimizer` can fit `Scheduler.Parameters` from existing `ReviewLog` values
  and estimate an efficient target retention from timed reviews
- `Scheduler.review(...)` returns a `ReviewResult` instead of a tuple

## Example

```swift
import FSRS

let scheduler = Scheduler()
let card = Card()

let result = try scheduler.review(
    card,
    rating: .good,
    at: .now,
    elapsed: .seconds(12)
)

let updatedCard = result.updatedCard
let reviewLog = result.reviewLog
```

## Configuration

```swift
let configuration = try Scheduler.Configuration(
    targetRetention: 0.92,
    learningStepDurations: [.seconds(60), .seconds(600)],
    relearningStepDurations: [.seconds(600)],
    maximumIntervalDays: 3650,
    fuzzingPolicy: .disabled
)

let scheduler = Scheduler(configuration: configuration)
```

## Optimizer

```swift
let optimizer = Optimizer(reviewLogs: reviewLogs)
let parameters = optimizer.computeOptimalParameters()
let retention = try optimizer.computeOptimalRetention(parameters: parameters)

let optimizedConfiguration = try Scheduler.Configuration(
    parameters: parameters,
    targetRetention: retention
)
let optimizedScheduler = Scheduler(configuration: optimizedConfiguration)
```

`computeOptimalRetention(parameters:)` requires `ReviewLog.elapsed` durations so
the optimizer can model review cost. The API uses `Scheduler.Parameters` rather
than raw weight arrays, but `parameters.weights` is available if you need to
serialize the fitted model.

## Deterministic fuzz testing

```swift
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

var generator = SeededGenerator(state: 42)
let result = try scheduler.review(card, rating: .good, using: &generator)
```
