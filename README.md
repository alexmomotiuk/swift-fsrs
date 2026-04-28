A pure Swift implementation of FSRS.

`swift-fsrs` keeps the current scheduler math and defaults from modern FSRS,
but exposes them through a Swift-native API built around value types:

- `Card` uses `dueDate`, `lastReviewedAt`, and a typed `CardState`
- `ReviewLog` stores `reviewedAt` and optional `Duration`-based `elapsed`
- `Scheduler.Configuration` groups retention, step durations, interval limits,
  parameter weights, and fuzzing policy
- `Scheduler.review(...)` returns a `ReviewResult` instead of a tuple

## iOS app flow

FSRS does not load cards from your database and it does not decide which 10
rows to fetch. Your app owns storage. The library only does scheduling math.

1. Load the stored `Card` for the prompt you are about to show.
2. Call `Scheduler.review(...)` with the user's rating.
3. Persist `result.updatedCard`.
4. Append `result.reviewLog` to your review history.
5. Use `updatedCard.dueDate` as the next scheduled time for that card.

```swift
import FSRS

let scheduler = Scheduler()

let card = try loadStoredCard(id: cardID) ?? Card(id: cardID, dueDate: .now)

let reviewedAt = Date()
let answerTime: Duration = .seconds(12)

let result = try scheduler.review(
    card,
    rating: .good,
    at: reviewedAt,
    elapsed: answerTime
)

saveCard(result.updatedCard)
appendReviewLog(result.reviewLog)

let nextDueDate = result.updatedCard.dueDate
let retrievability = scheduler.retrievability(of: result.updatedCard, at: reviewedAt)

print("Show this card again at:", nextDueDate)
print("Current retrievability:", retrievability)
```

`loadStoredCard`, `saveCard`, and `appendReviewLog` are app-defined persistence
functions, not part of the library API.

`Scheduler.review(...)` is the main library call. It takes the current `Card`
plus the user's rating and returns:

- `updatedCard` contains the next due date and the updated FSRS memory state.
- `reviewLog` is the event you can store for history, analytics, or syncing.

## Getting the next 10 cards to practice

To get the next 10 cards, query your storage for cards whose `dueDate <= now`,
sort by `dueDate`, and take the first 10.

The library does not have a `nextCards(limit:)` API because that is a storage
query, not scheduling logic.

```swift
func loadNextCardsToPractice(now: Date = .now, limit: Int = 10) throws -> [Card] {
    try database.loadCards(
        dueBeforeOrAt: now,
        sortedByDueDate: true,
        limit: limit
    )
}
```

In SQL terms, the query is:

```sql
SELECT fsrs_card_json
FROM cards
WHERE due_date <= ?
ORDER BY due_date ASC
LIMIT 10;
```

If you also want to introduce new cards when fewer than 10 are due, that is
also app policy. A common rule is:

1. Load due review cards with `dueDate <= now`.
2. If fewer than 10 were found, load additional new cards in creation order.
3. Convert those new rows into `Card(id:dueDate:)` if they do not have stored
   FSRS state yet.

## What to persist

For normal app usage, persist these values:

- `Card` for each flashcard. This is the source of truth for scheduling.
- `ReviewLog` entries as an append-only history.
- Your own flashcard content such as front text, back text, tags, deck ID, and
  created date. FSRS does not store card content.
- `Scheduler.Configuration` if you customize the defaults.

You usually do not need to persist anything else:

- Do not store `retrievability`; recompute it with `scheduler.retrievability(...)`.
- Do not store a separate interval field; `updatedCard.dueDate` is the value
  you query against.
- Do not split out `stability` and `difficulty` into separate columns unless
  you want to denormalize for your own queries. They are already stored inside
  `Card.state`.

`ReviewLog.elapsed` is optional. Store it if you care how long the user spent
answering, otherwise pass `nil`.

## Storage options

### File storage

Good for small personal decks.

- Store an array of your app models as JSON in the documents directory.
- Each row should include your flashcard content plus the `Card`.
- To get the next 10 cards, decode the file, filter `dueDate <= now`, sort by
  `dueDate`, and take 10.

```swift
struct StoredFlashcard: Codable {
    var id: UUID
    var front: String
    var back: String
    var fsrsCard: Card?
}
```

If `fsrsCard` is `nil`, treat it as a new card:

```swift
let schedulingCard = stored.fsrsCard ?? Card(id: stored.id, dueDate: .now)
```

### UserDefaults

Only reasonable for very small datasets.

- Encode `[StoredFlashcard]` or `[UUID: StoredFlashcard]` into `Data`.
- Read all values, decode, then filter and sort in memory.
- Do not use this for large decks because every fetch becomes a full reload.

### SQLite

Best choice for larger decks.

- Keep your content columns in the `cards` table.
- Store FSRS state as either separate columns or a single JSON blob.
- Keep `due_date` as a real indexed column so you can fetch due cards quickly.

Example schema:

```sql
CREATE TABLE cards (
    id TEXT PRIMARY KEY,
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    due_date REAL NOT NULL,
    fsrs_card_json BLOB
);

CREATE INDEX cards_due_date_idx ON cards(due_date);
```

Suggested read flow:

1. Fetch 10 rows ordered by `due_date`.
2. Decode `fsrs_card_json` into `Card` when present.
3. If the blob is missing, create `Card(id:dueDate:)` for a new card.

Suggested write flow after a review:

1. Call `scheduler.review(card, rating:at:elapsed:)`.
2. Encode `result.updatedCard`.
3. Update `due_date` with `result.updatedCard.dueDate`.
4. Insert `result.reviewLog` into a `review_logs` table if you keep history.

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
