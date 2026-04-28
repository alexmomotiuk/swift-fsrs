public struct ReviewResult: Equatable, Codable, Sendable {
    public let updatedCard: Card
    public let reviewLog: ReviewLog

    public init(updatedCard: Card, reviewLog: ReviewLog) {
        self.updatedCard = updatedCard
        self.reviewLog = reviewLog
    }
}
