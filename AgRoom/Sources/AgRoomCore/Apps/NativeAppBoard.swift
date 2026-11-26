import Foundation

/// A bounded rectangular sliding-block ruleset. Coordinates are zero-based cells,
/// independent of pixels, gestures, models, files and host capabilities.
public struct NativeAppBoard: Codable, Equatable, Sendable {
    public struct Position: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }
    public struct Piece: Codable, Equatable, Sendable, Identifiable {
        public enum Axis: String, Codable, Sendable { case both, horizontal, vertical }
        public var id: String
        public var labelKey: String
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public var axis: Axis?
        public var initialPosition: Position { .init(x: x, y: y) }
    }
    public struct Goal: Codable, Equatable, Sendable {
        public var piece: String
        public var x: Int
        public var y: Int
    }
    public var columns: Int
    public var rows: Int
    public var persistent: Bool
    public var pieces: [Piece]
    public var goal: Goal

    public var initialProgress: NativeAppBoardProgress {
        .init(positions: Dictionary(uniqueKeysWithValues: pieces.map { ($0.id, $0.initialPosition) }))
    }

    public func validate(path: String) throws {
        guard (2...12).contains(columns), (2...12).contains(rows), (1...32).contains(pieces.count),
              Set(pieces.map(\.id)).count == pieces.count,
              pieces.allSatisfy({ NativeAppDefinition.validID($0.id) && !$0.labelKey.isEmpty
                  && (1...columns).contains($0.width) && (1...rows).contains($0.height) }),
              let target = pieces.first(where: { $0.id == goal.piece }),
              (0...(columns - target.width)).contains(goal.x), (0...(rows - target.height)).contains(goal.y) else {
            throw NativeAppError(.invalidDefinition, path: path)
        }
        do { try validatePositions(initialProgress.positions) }
        catch { throw NativeAppError(.invalidDefinition, path: path + ".pieces") }
    }

    /// Cosmetic labels/order may change without changing the saved game's rules.
    public func acceptsProgress(of old: NativeAppBoard) -> Bool {
        columns == old.columns && rows == old.rows && goal == old.goal && pieces.count == old.pieces.count
            && old.pieces.allSatisfy { previous in
                pieces.contains { $0.id == previous.id && $0.width == previous.width && $0.height == previous.height
                    && $0.initialPosition == previous.initialPosition && ($0.axis ?? .both) == (previous.axis ?? .both) }
            }
    }

    public func isWon(_ progress: NativeAppBoardProgress) -> Bool {
        progress.positions[goal.piece] == Position(x: goal.x, y: goal.y)
    }

    public func validateProgress(_ progress: NativeAppBoardProgress) throws {
        guard (0...1_000_000_000).contains(progress.moves), progress.moves >= progress.undo.count,
              progress.undo.count + progress.redo.count <= NativeAppBoardProgress.maximumHistory,
              progress.moves <= 1_000_000_000 - progress.redo.count else {
            throw NativeAppError(.incompatibleState)
        }
        try validatePositions(progress.positions)
        var before = progress.positions
        for move in progress.undo.reversed() {
            guard before[move.piece] == move.to else { throw NativeAppError(.incompatibleState) }
            try validateMove(piece: move.piece, from: move.to, to: move.from, positions: before)
            before[move.piece] = move.from
            guard before[goal.piece] != Position(x: goal.x, y: goal.y) else { throw NativeAppError(.incompatibleState) }
        }
        // Before history eviction, the entire history must lead back to the level.
        if progress.moves == progress.undo.count, before != initialProgress.positions {
            throw NativeAppError(.incompatibleState)
        }
        var after = progress.positions
        for move in progress.redo.reversed() {
            guard after[move.piece] == move.from, after[goal.piece] != Position(x: goal.x, y: goal.y) else {
                throw NativeAppError(.incompatibleState)
            }
            try validateMove(piece: move.piece, from: move.from, to: move.to, positions: after)
            after[move.piece] = move.to
        }
    }

    public func moving(_ progress: NativeAppBoardProgress, piece: String, dx: Int, dy: Int) throws -> NativeAppBoardProgress {
        try validateProgress(progress)
        guard !isWon(progress) else { throw NativeAppBoardError.finished }
        guard (-columns...columns).contains(dx), (-rows...rows).contains(dy), let from = progress.positions[piece] else {
            throw NativeAppBoardError.illegalMove
        }
        let to = Position(x: from.x + dx, y: from.y + dy)
        try validateMove(piece: piece, from: from, to: to, positions: progress.positions)
        guard progress.moves < 1_000_000_000 else { throw NativeAppError(.capacity) }
        var next = progress
        next.positions[piece] = to
        next.moves += 1
        next.undo.append(.init(piece: piece, from: from, to: to))
        if next.undo.count > NativeAppBoardProgress.maximumHistory { next.undo.removeFirst() }
        next.redo = []
        return next
    }

    public func undoing(_ progress: NativeAppBoardProgress) throws -> NativeAppBoardProgress {
        try validateProgress(progress)
        guard let move = progress.undo.last else { return progress }
        var next = progress
        next.undo.removeLast(); next.redo.append(move)
        next.positions[move.piece] = move.from; next.moves -= 1
        return next
    }

    public func redoing(_ progress: NativeAppBoardProgress) throws -> NativeAppBoardProgress {
        try validateProgress(progress)
        guard let move = progress.redo.last else { return progress }
        guard !isWon(progress) else { throw NativeAppBoardError.finished }
        var next = progress
        next.redo.removeLast(); next.undo.append(move)
        next.positions[move.piece] = move.to; next.moves += 1
        return next
    }

    /// Safe even for untrusted gesture deltas; the reducer remains authoritative.
    public func canMove(_ progress: NativeAppBoardProgress, piece: String, dx: Int, dy: Int) -> Bool {
        guard !isWon(progress), (-columns...columns).contains(dx), (-rows...rows).contains(dy),
              let from = progress.positions[piece] else { return false }
        return (try? validateMove(piece: piece, from: from, to: .init(x: from.x + dx, y: from.y + dy), positions: progress.positions)) != nil
    }

    private func validatePositions(_ positions: [String: Position]) throws {
        guard Set(positions.keys) == Set(pieces.map(\.id)) else { throw NativeAppError(.incompatibleState) }
        var occupied = Set<Int>()
        for piece in pieces {
            guard let point = positions[piece.id], point.x >= 0, point.y >= 0,
                  point.x <= columns - piece.width, point.y <= rows - piece.height else {
                throw NativeAppError(.incompatibleState)
            }
            for y in point.y..<(point.y + piece.height) {
                for x in point.x..<(point.x + piece.width) {
                    guard occupied.insert(y * columns + x).inserted else { throw NativeAppError(.incompatibleState) }
                }
            }
        }
    }

    private func validateMove(piece id: String, from: Position, to: Position, positions: [String: Position]) throws {
        guard let piece = pieces.first(where: { $0.id == id }), positions[id] == from,
              to.x >= 0, to.y >= 0, to.x <= columns - piece.width, to.y <= rows - piece.height,
              (from.x == to.x) != (from.y == to.y),
              piece.axis != .horizontal || from.y == to.y,
              piece.axis != .vertical || from.x == to.x else { throw NativeAppBoardError.illegalMove }
        let dx = to.x == from.x ? 0 : (to.x > from.x ? 1 : -1)
        let dy = to.y == from.y ? 0 : (to.y > from.y ? 1 : -1)
        var point = from
        repeat {
            point.x += dx; point.y += dy
            for other in pieces where other.id != id {
                guard let origin = positions[other.id] else { throw NativeAppError(.incompatibleState) }
                if point.x < origin.x + other.width && origin.x < point.x + piece.width
                    && point.y < origin.y + other.height && origin.y < point.y + piece.height {
                    throw NativeAppBoardError.illegalMove
                }
            }
        } while point != to
    }
}

public struct NativeAppBoardProgress: Codable, Equatable, Sendable {
    public struct Move: Codable, Equatable, Sendable {
        public let piece: String
        public let from: NativeAppBoard.Position
        public let to: NativeAppBoard.Position
    }
    public static let maximumHistory = 128
    public var positions: [String: NativeAppBoard.Position]
    public var moves: Int
    public var undo: [Move]
    public var redo: [Move]
    public init(positions: [String: NativeAppBoard.Position], moves: Int = 0, undo: [Move] = [], redo: [Move] = []) {
        self.positions = positions; self.moves = moves; self.undo = undo; self.redo = redo
    }
}

public enum NativeAppBoardError: String, Error, Sendable {
    case illegalMove, finished
    public var localizationKey: String { "apps.board.error." + rawValue }
}
