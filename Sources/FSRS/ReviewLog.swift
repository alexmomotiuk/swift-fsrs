import Foundation

public struct ReviewLog: Equatable, Codable, Sendable {
    public let cardID: UUID
    public let rating: ReviewRating
    public let reviewedAt: Date
    public let elapsed: Duration?

    public init(
        cardID: UUID,
        rating: ReviewRating,
        reviewedAt: Date,
        elapsed: Duration? = nil
    ) {
        self.cardID = cardID
        self.rating = rating
        self.reviewedAt = reviewedAt
        self.elapsed = elapsed
    }

    private enum CodingKeys: String, CodingKey {
        case cardID
        case rating
        case reviewedAt
        case elapsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardID = try container.decode(UUID.self, forKey: .cardID)
        rating = try container.decode(ReviewRating.self, forKey: .rating)
        reviewedAt = try container.decode(Date.self, forKey: .reviewedAt)
        elapsed = try container.decodeIfPresent(CodableDuration.self, forKey: .elapsed)?.duration
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cardID, forKey: .cardID)
        try container.encode(rating, forKey: .rating)
        try container.encode(reviewedAt, forKey: .reviewedAt)
        try container.encodeIfPresent(elapsed.map(CodableDuration.init), forKey: .elapsed)
    }
}
