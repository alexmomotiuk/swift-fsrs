import Foundation

public struct MemoryState: Equatable, Codable, Sendable {
    public let stability: Double
    public let difficulty: Double

    public init(stability: Double, difficulty: Double) {
        self.stability = stability
        self.difficulty = difficulty
    }
}

public enum CardState: Equatable, Codable, Sendable {
    case new
    case learning(step: UInt, memory: MemoryState)
    case review(memory: MemoryState)
    case relearning(step: UInt, memory: MemoryState)

    private enum CodingKeys: String, CodingKey {
        case type
        case step
        case memory
    }

    private enum Kind: String, Codable {
        case new
        case learning
        case review
        case relearning
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)

        switch kind {
        case .new:
            self = .new
        case .learning:
            self = .learning(
                step: try container.decode(UInt.self, forKey: .step),
                memory: try container.decode(MemoryState.self, forKey: .memory)
            )
        case .review:
            self = .review(memory: try container.decode(MemoryState.self, forKey: .memory))
        case .relearning:
            self = .relearning(
                step: try container.decode(UInt.self, forKey: .step),
                memory: try container.decode(MemoryState.self, forKey: .memory)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .new:
            try container.encode(Kind.new, forKey: .type)
        case let .learning(step, memory):
            try container.encode(Kind.learning, forKey: .type)
            try container.encode(step, forKey: .step)
            try container.encode(memory, forKey: .memory)
        case let .review(memory):
            try container.encode(Kind.review, forKey: .type)
            try container.encode(memory, forKey: .memory)
        case let .relearning(step, memory):
            try container.encode(Kind.relearning, forKey: .type)
            try container.encode(step, forKey: .step)
            try container.encode(memory, forKey: .memory)
        }
    }
}

extension CardState {
    var memory: MemoryState? {
        switch self {
        case .new:
            return nil
        case let .learning(_, memory),
             let .review(memory),
             let .relearning(_, memory):
            return memory
        }
    }

    var step: UInt? {
        switch self {
        case .new, .review:
            return nil
        case let .learning(step, _), let .relearning(step, _):
            return step
        }
    }

    var isReviewed: Bool {
        if case .new = self {
            return false
        }
        return true
    }
}
