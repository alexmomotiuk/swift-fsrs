import Foundation

public struct Card: Identifiable, Equatable, Codable, Sendable {
    public internal(set) var id: UUID
    public internal(set) var dueDate: Date
    public internal(set) var lastReviewedAt: Date?
    public internal(set) var state: CardState

    public init(id: UUID = UUID(), dueDate: Date = Date()) {
        self.id = id
        self.dueDate = dueDate
        lastReviewedAt = nil
        state = .new
    }

    public init(
        id: UUID = UUID(),
        dueDate: Date,
        lastReviewedAt: Date,
        state: CardState
    ) throws {
        try Self.validate(lastReviewedAt: lastReviewedAt, state: state)
        self.id = id
        self.dueDate = dueDate
        self.lastReviewedAt = lastReviewedAt
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case dueDate
        case lastReviewedAt
        case state
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let dueDate = try container.decode(Date.self, forKey: .dueDate)
        let lastReviewedAt = try container.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        let state = try container.decode(CardState.self, forKey: .state)

        if let lastReviewedAt {
            try self.init(id: id, dueDate: dueDate, lastReviewedAt: lastReviewedAt, state: state)
        } else {
            guard state == .new else {
                throw FSRSError.invalidCardState(.reviewedCardRequiresLastReviewedAt)
            }
            self = Card(id: id, dueDate: dueDate)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(dueDate, forKey: .dueDate)
        try container.encodeIfPresent(lastReviewedAt, forKey: .lastReviewedAt)
        try container.encode(state, forKey: .state)
    }

    private static func validate(lastReviewedAt: Date, state: CardState) throws {
        guard state.isReviewed else {
            throw FSRSError.invalidCardState(.newCardCannotHaveLastReviewedAt)
        }
    }
}
