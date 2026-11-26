import Foundation

/// One send in a repeat run.
public struct RepeatSample: Equatable, Sendable {
    /// How long the request took, or nil when it did not complete.
    public var seconds: Double?
    public var status: Int?
    /// Why it did not complete.
    public var error: String?
    /// Assertions and script tests that failed.
    public var failedTests: Int

    public init(seconds: Double? = nil, status: Int? = nil, error: String? = nil, failedTests: Int = 0) {
        self.seconds = seconds
        self.status = status
        self.error = error
        self.failedTests = failedTests
    }

    public init(_ result: RequestRunResult) {
        self.init(
            seconds: result.response?.timings.total,
            status: result.response?.status,
            error: result.response == nil ? (result.error ?? "The request did not run.") : nil,
            failedTests: result.failedTests.count + (result.scriptError == nil ? 0 : 1)
        )
    }

    /// True when the request did not complete, the server answered with a 4xx or 5xx, or a test failed.
    public var isError: Bool {
        error != nil || (status ?? 0) >= 400 || failedTests > 0
    }
}

/// Latency percentiles and the error rate over a set of sends.
public struct LatencyStats: Equatable, Sendable {
    public var count = 0
    public var errors = 0
    /// Sends that got no response at all.
    public var incomplete = 0
    /// How many responses had each status code.
    public var statuses: [Int: Int] = [:]
    public var minimum = 0.0
    public var maximum = 0.0
    public var mean = 0.0
    public var p50 = 0.0
    public var p90 = 0.0
    public var p95 = 0.0
    public var p99 = 0.0

    public var errorRate: Double { count == 0 ? 0 : Double(errors) / Double(count) }

    public init(_ samples: [RepeatSample]) {
        count = samples.count
        errors = samples.filter(\.isError).count
        incomplete = samples.filter { $0.status == nil }.count
        for sample in samples {
            if let status = sample.status { statuses[status, default: 0] += 1 }
        }
        let times = samples.compactMap(\.seconds).sorted()
        guard let first = times.first, let last = times.last else { return }
        minimum = first
        maximum = last
        mean = times.reduce(0, +) / Double(times.count)
        p50 = Self.percentile(times, 0.50)
        p90 = Self.percentile(times, 0.90)
        p95 = Self.percentile(times, 0.95)
        p99 = Self.percentile(times, 0.99)
    }

    /// The value a given share of the samples fall at or below, reading between the two
    /// nearest samples when the position is not a whole number. `sorted` must be ascending.
    public static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = min(max(fraction, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Counts of samples in equal-width bands from the fastest to the slowest, for drawing a histogram.
    public static func histogram(_ seconds: [Double], bands: Int = 20) -> [(from: Double, to: Double, count: Int)] {
        guard let low = seconds.min(), let high = seconds.max(), bands > 0 else { return [] }
        let width = max((high - low) / Double(bands), 0.000_001)
        var counts = Array(repeating: 0, count: bands)
        for value in seconds {
            counts[min(bands - 1, Int((value - low) / width))] += 1
        }
        return counts.enumerated().map { (low + Double($0.offset) * width, low + Double($0.offset + 1) * width, $0.element) }
    }
}

/// Ranks names against what was typed into the command palette.
public enum FuzzyMatch {
    /// A score for how well `text` matches `query`, higher being better, or nil when it does
    /// not match. Every word of the query must appear: as a run of letters if possible,
    /// otherwise as letters in order with gaps.
    public static func score(_ query: String, in text: String) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var total = 0
        for word in words {
            guard let score = score(word: Array(word), in: haystack) else { return nil }
            total += score
        }
        // Between equal matches, the shorter name is the closer one.
        return total - haystack.count / 8
    }

    private static func isBoundary(_ haystack: [Character], _ index: Int) -> Bool {
        index == 0 || !(haystack[index - 1].isLetter || haystack[index - 1].isNumber)
    }

    private static func score(word: [Character], in haystack: [Character]) -> Int? {
        guard word.count <= haystack.count else { return nil }
        // A run of letters: best at the start of the text, next best at the start of a word.
        var best: Int?
        if !word.isEmpty {
            for start in 0...(haystack.count - word.count) where Array(haystack[start..<start + word.count]) == word {
                let score = 100 + word.count * 4 + (start == 0 ? 40 : isBoundary(haystack, start) ? 25 : 0)
                best = max(best ?? 0, score)
            }
        }
        if let best { return best }
        // Letters in order, with gaps.
        var score = 0
        var position = 0
        var previous = -2
        for character in word {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            score += 4
            if found == previous + 1 { score += 6 }
            if isBoundary(haystack, found) { score += 8 }
            previous = found
            position = found + 1
        }
        return score
    }
}
