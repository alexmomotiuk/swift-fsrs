import Foundation

struct CodableDuration: Codable, Equatable {
    let seconds: Int64
    let attoseconds: Int64

    init(_ duration: Duration) {
        let components = duration.components
        seconds = components.seconds
        attoseconds = components.attoseconds
    }

    var duration: Duration {
        Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}
