public enum ReviewRating: String, Codable, CaseIterable, Sendable {
    case again
    case hard
    case good
    case easy
    
    var ordinal: Int {
        switch self {
            case .again: 1
            case .hard: 2
            case .good: 3
            case .easy: 4
        }
    }
}
