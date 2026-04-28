A Swift implementation of FSRS6.

## iOS app integration

`swift-fsrs` is a scheduling engine. It does not fetch cards from your file,
`UserDefaults`, or SQLite database. Your app owns storage and decides which
cards to show next. The library takes a stored `Card`, applies FSRS math, and
returns an updated `Card` plus a `ReviewLog`.

The main calls are:

- `FSRS(parameters:)` to create the scheduler
- `repeat(card:now:)` to preview the result for `.again`, `.hard`, `.good`, and `.easy`
- `next(card:now:grade:)` to commit the rating the user picked
- `getRetrievability(card:now:)` to compute current retrievability

## Review flow

Typical app flow:

1. Load a stored `Card` from your database.
2. If the flashcard has never been scheduled before, create one with `Card(due:)`.
3. Optionally call `repeat(card:now:)` to preview all answer buttons.
4. When the user answers, call `next(card:now:grade:)`.
5. Save the returned `RecordLogItem.card` back to storage.
6. Optionally append `RecordLogItem.log` to your review history table.

```swift
import FSRS
import Foundation

let parameters = FSRSParameters()
let fsrs = FSRS(parameters: parameters)

let reviewDate = Date()
let card = try loadStoredCard(id: cardID) ?? Card(cardID: cardID, due: reviewDate)

let preview = fsrs.repeat(card: card, now: reviewDate)
let goodDueDate = preview[.good]?.card.due

let result = try fsrs.next(
    card: card,
    now: reviewDate,
    grade: .good
)

saveCard(result.card)
appendReviewLog(result.log)
```

`loadStoredCard`, `saveCard`, and `appendReviewLog` are app-defined storage
functions, not part of the library.

## Which type to persist

For each flashcard, persist the library `Card` alongside your own content:

```swift
struct StoredFlashcard: Codable {
    var id: Int
    var front: String
    var back: String
    var fsrsCard: Card?
}
```

If `fsrsCard` is `nil`, the item is a new card. Create it like this when the
user studies it for the first time:

```swift
let card = stored.fsrsCard ?? Card(cardID: stored.id, due: Date())
```

The `Card` already contains the scheduling state you need:

- `due`
- `stability`
- `difficulty`
- `elapsedDays`
- `scheduledDays`
- `reps`
- `lapses`
- `state`
- `step`
- `lastReview`

You usually do not need to duplicate those fields elsewhere unless it helps
your database queries.

`ReviewLog` is optional for normal scheduling, but useful if you want review
history, analytics, sync, or replay/migration workflows later.

## How to get the next 10 cards to practice

The library does not have a `nextCards(limit:)` function because fetching due
cards is a storage concern, not a scheduling concern.

To get the next 10 cards:

1. Query your storage for cards whose due date is now or earlier.
2. Sort by due date ascending.
3. Take the first 10 rows.
4. Decode the stored `Card` for each row.

In app code that looks like:

```swift
func loadNextCardsToPractice(now: Date = .now, limit: Int = 10) throws -> [StoredFlashcard] {
    try database.loadFlashcards(
        dueBeforeOrAt: now,
        sortedByDueDate: true,
        limit: limit
    )
}
```

In SQL terms it is:

```sql
SELECT id, front, back, due_date, fsrs_card_json
FROM cards
WHERE due_date <= ?
ORDER BY due_date ASC
LIMIT 10;
```

If fewer than 10 review cards are due, and you want to mix in new cards, that
is app policy. A common approach is:

1. Load due review cards first.
2. If you have fewer than 10, load additional unseen cards in creation order.
3. Treat those unseen cards as `Card(cardID:due:)` when the user starts them.

## Storage choices

### JSON file

Good for small personal decks.

- Store `[StoredFlashcard]` in the documents directory.
- Decode the whole file, filter `fsrsCard?.due <= now`, sort by due date, take 10.
- If `fsrsCard` is missing, treat the card as new.

### UserDefaults

Only reasonable for very small datasets.

- Store encoded `Data` for `[StoredFlashcard]` or `[Int: StoredFlashcard]`.
- Read all values into memory, decode, filter, sort, and take 10.
- This does not scale well for larger decks.

### SQLite

Best option for larger decks.

- Keep a `due_date` column for fast queries.
- Store the library `Card` either as JSON or as decomposed columns.
- Index `due_date`.

Example schema:

```sql
CREATE TABLE cards (
    id INTEGER PRIMARY KEY,
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    due_date REAL NOT NULL,
    fsrs_card_json BLOB
);

CREATE INDEX cards_due_date_idx ON cards(due_date);
```

Suggested read flow:

1. Fetch due rows ordered by `due_date`.
2. Decode `fsrs_card_json` into `Card` when present.
3. If missing, create a new card with `Card(cardID:due:)`.

Suggested write flow after review:

1. Call `fsrs.next(card:now:grade:)`.
2. Save `result.card` back into the row.
3. Update the indexed `due_date` column with `result.card.due`.
4. Optionally insert `result.log` into a separate `review_logs` table.

## Previewing answer buttons

If your UI shows the next interval for each answer button before the user taps,
use `repeat(card:now:)`:

```swift
let preview = fsrs.repeat(card: card, now: Date())

let again = preview[.again]
let hard = preview[.hard]
let good = preview[.good]
let easy = preview[.easy]
```

Each preview item contains:

- `card`: the hypothetical next `Card` if the user chooses that rating
- `log`: the corresponding review log entry

That is useful for button subtitles like “Again 1m” or “Good 3d”.

## Retrievability

To compute current retrievability for a stored card:

```swift
let retrievability = fsrs.getRetrievability(card: card, now: Date())
print(retrievability.string)
print(retrievability.number)
```

You do not need to persist retrievability. Recompute it when needed.

## Configuration

Use `FSRSParameters` to customize retention, maximum interval, fuzzing, or
learning steps:

```swift
let parameters = FSRSParameters(
    requestRetention: 0.9,
    maximumInterval: 3650,
    enableFuzz: false,
    enableShortTerm: true,
    learningSteps: [1, 10],
    relearningSteps: [10]
)

let fsrs = FSRS(parameters: parameters)
```
