import SwiftUI
import AgRoomCore

/// Presentation and input only. Every input path commits through the same Core reducer.
struct NativeAppBoardView: View {
    let boardID: String
    @Bindable var model: NativeAppRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: String?

    var body: some View {
        if let board = model.definition.boards?[boardID], let progress = model.boardProgress[boardID] {
            VStack(spacing: 12) {
                HStack {
                    Text(L.format("apps.board.moves", progress.moves)).monospacedDigit()
                    Spacer()
                    if board.isWon(progress) {
                        Label(L.string("apps.board.won"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }.font(.headline)
                GeometryReader { geometry in
                    let cell = min(geometry.size.width / CGFloat(board.columns), geometry.size.height / CGFloat(board.rows))
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08))
                        grid(board, cell: cell)
                        ForEach(board.pieces) { piece in
                            if let position = progress.positions[piece.id] {
                                NativeAppBoardPieceView(piece: piece, board: board, progress: progress,
                                    position: position, cell: cell, selected: selected == piece.id,
                                    enabled: model.isReady && model.isActive && !model.isBusy,
                                    label: model.text(piece.labelKey), reduceMotion: reduceMotion,
                                    select: { selected = piece.id },
                                    move: { dx, dy, expected in
                                        model.moveBoard(boardID, piece: piece.id, dx: dx, dy: dy, expected: expected)
                                    })
                            }
                        }
                    }.frame(width: cell * CGFloat(board.columns), height: cell * CGFloat(board.rows))
                }
                .aspectRatio(CGFloat(board.columns) / CGFloat(board.rows), contentMode: .fit)
                .frame(maxWidth: 440)
                HStack(spacing: 16) {
                    direction("apps.board.left", symbol: "arrow.left", dx: -1, dy: 0, board: board, progress: progress)
                    direction("apps.board.up", symbol: "arrow.up", dx: 0, dy: -1, board: board, progress: progress)
                    direction("apps.board.down", symbol: "arrow.down", dx: 0, dy: 1, board: board, progress: progress)
                    direction("apps.board.right", symbol: "arrow.right", dx: 1, dy: 0, board: board, progress: progress)
                }
                Text(L.string("apps.board.hint")).font(.caption).foregroundStyle(.secondary)
                if let message = model.boardFeedback[boardID] {
                    Text(message).font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                }
            }
            .frame(maxWidth: 480)
            .onChange(of: model.isActive) { _, active in if !active { selected = nil } }
        }
    }

    private func grid(_ board: NativeAppBoard, cell: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for x in 1..<board.columns {
                    path.move(to: CGPoint(x: CGFloat(x) * cell, y: 0))
                    path.addLine(to: CGPoint(x: CGFloat(x) * cell, y: CGFloat(board.rows) * cell))
                }
                for y in 1..<board.rows {
                    path.move(to: CGPoint(x: 0, y: CGFloat(y) * cell))
                    path.addLine(to: CGPoint(x: CGFloat(board.columns) * cell, y: CGFloat(y) * cell))
                }
            }.stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            if let target = board.pieces.first(where: { $0.id == board.goal.piece }) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                    .frame(width: CGFloat(target.width) * cell - 4, height: CGFloat(target.height) * cell - 4)
                    .offset(x: CGFloat(board.goal.x) * cell + 2, y: CGFloat(board.goal.y) * cell + 2)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func direction(_ key: String, symbol: String, dx: Int, dy: Int, board: NativeAppBoard, progress: NativeAppBoardProgress) -> some View {
        Button {
            guard let selected else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                _ = model.moveBoard(boardID, piece: selected, dx: dx, dy: dy)
            }
        } label: { Label(L.string(key), systemImage: symbol).labelStyle(.iconOnly).frame(minWidth: 28, minHeight: 24) }
            .help(L.string(key))
            .disabled(selected == nil || !board.canMove(progress, piece: selected ?? "", dx: dx, dy: dy))
    }
}

private struct NativeAppBoardPieceView: View {
    let piece: NativeAppBoard.Piece
    let board: NativeAppBoard
    let progress: NativeAppBoardProgress
    let position: NativeAppBoard.Position
    let cell: CGFloat
    let selected: Bool
    let enabled: Bool
    let label: String
    let reduceMotion: Bool
    let select: () -> Void
    let move: (Int, Int, NativeAppBoardProgress?) -> Bool
    @State private var translation = CGSize.zero
    @State private var dragOrigin: NativeAppBoardProgress?
    @GestureState private var dragActive = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: { focused = true; select() }) {
            pieceLabel
        }
        .buttonStyle(.plain)
        .focusable().focused($focused).focusEffectDisabled()
        .offset(x: CGFloat(position.x) * cell + 4 + translation.width, y: CGFloat(position.y) * cell + 4 + translation.height)
        .zIndex(dragOrigin == nil ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: position)
        .simultaneousGesture(DragGesture(minimumDistance: 4)
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { value in
                guard enabled, !board.isWon(progress), cell > 0 else { return }
                if dragOrigin == nil { dragOrigin = progress; focused = true; select() }
                translation = constrained(value.translation)
            }
            .onEnded { value in
                guard enabled, let origin = dragOrigin, cell > 0 else { resetDrag(); return }
                let offset = constrained(value.translation)
                let dx = Int((offset.width / cell).rounded())
                let dy = Int((offset.height / cell).rounded())
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                    translation = .zero; dragOrigin = nil
                    if dx != 0 || dy != 0 { _ = move(dx, dy, origin) }
                }
            })
        .onKeyPress(.leftArrow) { keyMove(-1, 0) }
        .onKeyPress(.rightArrow) { keyMove(1, 0) }
        .onKeyPress(.upArrow) { keyMove(0, -1) }
        .onKeyPress(.downArrow) { keyMove(0, 1) }
        .accessibilityLabel(label)
        .accessibilityValue(L.format("apps.board.position", position.x + 1, position.y + 1))
        .accessibilityHint(L.string("apps.board.pieceHint"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(L.string("apps.board.left"))) { _ = keyMove(-1, 0) }
        .accessibilityAction(named: Text(L.string("apps.board.right"))) { _ = keyMove(1, 0) }
        .accessibilityAction(named: Text(L.string("apps.board.up"))) { _ = keyMove(0, -1) }
        .accessibilityAction(named: Text(L.string("apps.board.down"))) { _ = keyMove(0, 1) }
        .onChange(of: enabled) { _, active in if !active { resetDrag() } }
        .onChange(of: dragActive) { _, active in if !active { resetDrag() } }
        .onDisappear { resetDrag() }
    }

    private var pieceLabel: some View {
        let isGoal: Bool = board.goal.piece == piece.id
        let font: Font = isGoal ? .title2.bold() : .headline
        let fill: Color = isGoal ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.16)
        let border: Color = selected ? Color.accentColor : Color.secondary.opacity(0.2)
        let borderWidth: CGFloat = selected ? 3 : 1
        let width: CGFloat = CGFloat(piece.width) * cell - 8
        let height: CGFloat = CGFloat(piece.height) * cell - 8
        return Text(label)
            .font(font)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.65)
            .lineLimit(2)
            .padding(6)
            .frame(width: width, height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: borderWidth))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func resetDrag() { translation = .zero; dragOrigin = nil }

    private func keyMove(_ dx: Int, _ dy: Int) -> KeyPress.Result {
        guard enabled else { return .ignored }
        select()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { _ = move(dx, dy, nil) }
        return .handled
    }

    /// Clamp presentation against every intervening cell, so a pointer cannot
    /// visually tunnel through another piece. Commit independently checks again.
    private func constrained(_ offset: CGSize) -> CGSize {
        let horizontal = piece.axis == .horizontal || (piece.axis != .vertical && abs(offset.width) >= abs(offset.height))
        let distance = horizontal ? offset.width : offset.height
        let sign = distance < 0 ? -1 : 1
        let maximum = horizontal ? board.columns : board.rows
        var cells = 0
        for step in 1...maximum {
            if !board.canMove(progress, piece: piece.id, dx: horizontal ? sign * step : 0, dy: horizontal ? 0 : sign * step) { break }
            cells = step
        }
        let bounded = min(abs(distance), CGFloat(cells) * cell) * CGFloat(sign)
        return horizontal ? CGSize(width: bounded, height: 0) : CGSize(width: 0, height: bounded)
    }
}
