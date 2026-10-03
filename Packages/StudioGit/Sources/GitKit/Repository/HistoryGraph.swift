import Foundation

/// Lane layout for drawing a commit graph, one row per commit.
///
/// Each row is drawn in two halves: the upper half connects lanes coming
/// from the row above to this row's node or straight through, and the lower
/// half connects the node (or pass-through lanes) to lanes in the row below.
/// Lanes keep their column for their whole life, which keeps long branches
/// straight; free columns are reused.
public struct GraphRow: Sendable, Hashable, Identifiable {
    public struct Segment: Sendable, Hashable {
        public var fromColumn: Int
        public var toColumn: Int
        /// Stable color index for the lane the segment belongs to.
        public var color: Int
    }

    public var commit: CommitInfo
    /// Column of this commit's node.
    public var column: Int
    public var color: Int
    /// Segments from the top edge of the row (from) to its middle (to).
    public var upper: [Segment]
    /// Segments from the middle of the row (from) to its bottom edge (to).
    public var lower: [Segment]
    /// Number of columns this row needs.
    public var width: Int

    public var id: ObjectID { commit.id }
}

public enum HistoryGraph {
    /// Lays out commits given in topological order (children before parents),
    /// as returned by `GitRepository.log`.
    public static func layout(_ commits: [CommitInfo]) -> [GraphRow] {
        var lanes: [ObjectID?] = []          // the commit each lane waits for
        var laneColor: [Int] = []
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeLane() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            laneColor.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            // Lanes arriving at this commit.
            let incoming = lanes.indices.filter { lanes[$0] == commit.id }
            let column: Int
            if let first = incoming.first {
                column = first
            } else {
                column = freeLane()
                laneColor[column] = nextColor
                nextColor += 1
            }
            let color = laneColor[column]

            var upper: [GraphRow.Segment] = []
            for i in lanes.indices {
                guard let waiting = lanes[i] else { continue }
                if waiting == commit.id {
                    upper.append(.init(fromColumn: i, toColumn: column, color: laneColor[i]))
                } else {
                    upper.append(.init(fromColumn: i, toColumn: i, color: laneColor[i]))
                }
            }
            for i in incoming where i != column { lanes[i] = nil }

            var lower: [GraphRow.Segment] = []
            // Pass-through lanes.
            for i in lanes.indices where i != column {
                if lanes[i] != nil {
                    lower.append(.init(fromColumn: i, toColumn: i, color: laneColor[i]))
                }
            }
            // Parents.
            lanes[column] = nil
            for (n, parent) in commit.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    lower.append(.init(fromColumn: column, toColumn: existing, color: laneColor[existing]))
                    continue
                }
                let lane: Int
                if n == 0 {
                    lane = column
                    laneColor[lane] = color
                } else {
                    lane = freeLane()
                    laneColor[lane] = nextColor
                    nextColor += 1
                }
                lanes[lane] = parent
                lower.append(.init(fromColumn: column, toColumn: lane, color: laneColor[lane]))
            }
            while let last = lanes.last, last == nil, lanes.count > column + 1 {
                lanes.removeLast()
                laneColor.removeLast()
            }
            let width = max(column + 1,
                            (upper.map { max($0.fromColumn, $0.toColumn) } + lower.map { max($0.fromColumn, $0.toColumn) }).max().map { $0 + 1 } ?? 0)
            rows.append(GraphRow(commit: commit, column: column, color: color, upper: upper, lower: lower, width: width))
        }
        return rows
    }
}
