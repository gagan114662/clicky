import AppKit
import SwiftUI

final class LessonVisualOverlayWindow: NSPanel {
    private var hostingController: NSHostingController<LessonVisualOverlayView>?

    init(rootView: LessonVisualOverlayView, screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let width = min(visibleFrame.width - 24, 1_420)
        let height = min(visibleFrame.height - 36, 860)
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        isReleasedWhenClosed = false
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hostingController = NSHostingController(rootView: rootView)
        self.hostingController = hostingController
        contentView = hostingController.view
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(rootView: LessonVisualOverlayView) {
        let hostingController = NSHostingController(rootView: rootView)
        self.hostingController = hostingController
        contentView = hostingController.view
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

final class LessonBoardNotesOverlayWindow: NSPanel {
    private var hostingController: NSHostingController<LessonBoardNotesOverlayView>?

    init(rootView: LessonBoardNotesOverlayView, screen: NSScreen) {
        super.init(
            contentRect: Self.frame(for: screen, noteCount: rootView.notes.count),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isReleasedWhenClosed = false
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hostingController = NSHostingController(rootView: rootView)
        self.hostingController = hostingController
        contentView = hostingController.view
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(rootView: LessonBoardNotesOverlayView, screen: NSScreen) {
        hostingController = NSHostingController(rootView: rootView)
        contentView = hostingController?.view
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        setFrame(Self.frame(for: screen, noteCount: rootView.notes.count), display: true)
    }

    private static func frame(for screen: NSScreen, noteCount: Int) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let width = min(560, visibleFrame.width * 0.30)
        let height = min(visibleFrame.height - 260, 96 + CGFloat(min(max(noteCount, 1), 5)) * 82)
        return NSRect(
            x: visibleFrame.minX + max(520, visibleFrame.width * 0.19),
            y: visibleFrame.minY + 160,
            width: width,
            height: height
        )
    }
}

@MainActor
final class LessonVisualOverlayWindowManager {
    private var window: LessonVisualOverlayWindow?
    private var notesWindow: LessonBoardNotesOverlayWindow?
    private var boardNotes: [String] = []
    private var currentSpec: FreeformDiagramSpec?
    private var currentCursorColor: Color = DS.Colors.overlayCursorBlue

    func show(spec: FreeformDiagramSpec) {
        let screen = Self.screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        currentSpec = spec
        currentCursorColor = DS.Colors.overlayCursorBlue
        boardNotes.removeAll()
        hideNotes()

        let rootView = LessonVisualOverlayView(
            spec: spec,
            cursorColor: currentCursorColor,
            boardNotes: boardNotes,
            onClose: { [weak self] in
                self?.hide()
            }
        )

        if let window {
            window.update(rootView: rootView)
            window.setFrame(Self.frame(for: screen), display: true)
            window.orderFrontRegardless()
        } else {
            let newWindow = LessonVisualOverlayWindow(rootView: rootView, screen: screen)
            window = newWindow
            newWindow.orderFrontRegardless()
        }
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        currentSpec = nil
        boardNotes.removeAll()
        hideNotes()
    }

    @discardableResult
    func addBoardNote(_ rawText: String) -> Int {
        let text = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(180)
            .description
        guard !text.isEmpty else { return boardNotes.count }

        boardNotes.append(text)
        if boardNotes.count > 5 {
            boardNotes.removeFirst(boardNotes.count - 5)
        }

        let screen = Self.screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return boardNotes.count }
        currentCursorColor = DS.Colors.overlayCursorBlue

        if let currentSpec {
            let rootView = LessonVisualOverlayView(
                spec: currentSpec,
                cursorColor: currentCursorColor,
                boardNotes: boardNotes,
                onClose: { [weak self] in
                    self?.hide()
                }
            )
            if let window {
                window.update(rootView: rootView)
                window.setFrame(Self.frame(for: screen), display: true)
                window.orderFrontRegardless()
            } else {
                let newWindow = LessonVisualOverlayWindow(rootView: rootView, screen: screen)
                window = newWindow
                newWindow.orderFrontRegardless()
            }
            hideNotes()
            return boardNotes.count
        }

        let rootView = LessonBoardNotesOverlayView(
            notes: boardNotes,
            cursorColor: currentCursorColor
        )
        if let notesWindow {
            notesWindow.update(rootView: rootView, screen: screen)
            notesWindow.orderFrontRegardless()
        } else {
            let newWindow = LessonBoardNotesOverlayWindow(rootView: rootView, screen: screen)
            notesWindow = newWindow
            newWindow.orderFrontRegardless()
        }
        return boardNotes.count
    }

    private func hideNotes() {
        notesWindow?.orderOut(nil)
        notesWindow = nil
    }

    private static func frame(for screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let width = min(visibleFrame.width - 24, 1_420)
        let height = min(visibleFrame.height - 36, 860)
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }
}

struct LessonBoardNotesOverlayView: View {
    let notes: [String]
    let cursorColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Triangle()
                    .fill(cursorColor)
                    .frame(width: 20, height: 20)
                    .shadow(color: cursorColor.opacity(0.55), radius: 8)
                Text("Board notes")
                    .font(.system(size: 18, weight: .black))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
            }

            ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 14, weight: .black))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(cursorColor))
                    Text(note)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.black.opacity(0.90))
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.96)))
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}

struct LessonVisualOverlayView: View {
    let spec: FreeformDiagramSpec
    let cursorColor: Color
    let boardNotes: [String]
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.98, green: 0.97, blue: 0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.black.opacity(0.14), lineWidth: 2)
                )

            VStack(alignment: .leading, spacing: 18) {
                header
                studioStrip
                VStack(spacing: 16) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !boardNotes.isEmpty {
                        notesShelf
                    }
                }
            }
            .padding(24)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.black.opacity(0.72)))
            }
            .buttonStyle(.plain)
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Triangle()
                .fill(cursorColor)
                .frame(width: 38, height: 38)
                .shadow(color: cursorColor.opacity(0.55), radius: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(spec.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.black.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(subtitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black.opacity(0.58))
            }

            Spacer(minLength: 64)
        }
    }

    private var studioStrip: some View {
        HStack(spacing: 10) {
            ForEach(Array(studioSteps.enumerated()), id: \.offset) { _, step in
                StudioStepPill(step: step)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch spec.kind {
        case .multiplicationArray:
            MultiplicationArrayLessonView()
        case .fractionBar:
            FractionBarLessonView()
        case .derivativeSlope:
            DerivativeSlopeLessonView()
        case .conceptMap:
            ConceptMapLessonView(title: spec.title)
        }
    }

    private var subtitle: String {
        switch spec.kind {
        case .multiplicationArray:
            return "Rows become groups you can inspect, flip, and explain"
        case .fractionBar:
            return "The whole stays visible while the shaded part changes"
        case .derivativeSlope:
            return "Zoom the curve until slope becomes something you can see"
        case .conceptMap:
            return "Turn the screen into parts, links, changes, and a next move"
        }
    }

    private var studioSteps: [StudioStep] {
        switch spec.kind {
        case .multiplicationArray:
            return [
                StudioStep(symbol: "eye", title: "See", detail: "one row"),
                StudioStep(symbol: "questionmark.circle", title: "Predict", detail: "total"),
                StudioStep(symbol: "arrow.left.arrow.right", title: "Change", detail: "flip it"),
                StudioStep(symbol: "text.bubble", title: "Own", detail: "say why")
            ]
        case .fractionBar:
            return [
                StudioStep(symbol: "rectangle.split.3x1", title: "See", detail: "whole"),
                StudioStep(symbol: "circle.lefthalf.filled", title: "Predict", detail: "shade"),
                StudioStep(symbol: "slider.horizontal.3", title: "Change", detail: "parts"),
                StudioStep(symbol: "text.bubble", title: "Own", detail: "name it")
            ]
        case .derivativeSlope:
            return [
                StudioStep(symbol: "magnifyingglass", title: "Zoom", detail: "point"),
                StudioStep(symbol: "chart.line.uptrend.xyaxis", title: "Predict", detail: "slope"),
                StudioStep(symbol: "arrow.up.right", title: "Change", detail: "tilt"),
                StudioStep(symbol: "text.bubble", title: "Own", detail: "rate")
            ]
        case .conceptMap:
            return [
                StudioStep(symbol: "circle.grid.2x2", title: "Pick", detail: "part"),
                StudioStep(symbol: "link", title: "Connect", detail: "relation"),
                StudioStep(symbol: "arrow.triangle.2.circlepath", title: "Change", detail: "case"),
                StudioStep(symbol: "text.bubble", title: "Own", detail: "why")
            ]
        }
    }

    private var notesShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Triangle()
                    .fill(cursorColor)
                    .frame(width: 16, height: 16)
                    .shadow(color: cursorColor.opacity(0.55), radius: 7)
                Text("Board notes")
                    .font(.system(size: 17, weight: .black))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
            }

            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(boardNotes.suffix(3).enumerated()), id: \.offset) { offset, note in
                    let absoluteIndex = boardNotes.count - boardNotes.suffix(3).count + offset + 1
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(absoluteIndex)")
                            .font(.system(size: 12, weight: .black))
                            .foregroundColor(.white)
                            .frame(width: 23, height: 23)
                            .background(Circle().fill(cursorColor))
                        Text(note)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.black.opacity(0.88))
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.96)))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct StudioStep: Equatable {
    let symbol: String
    let title: String
    let detail: String
}

private struct StudioStepPill: View {
    let step: StudioStep

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: step.symbol)
                .font(.system(size: 18, weight: .black))
                .foregroundColor(Color(red: 0.10, green: 0.12, blue: 0.16))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.90)))

            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(step.detail)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.76))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.86))
        )
    }
}

private struct MultiplicationArrayLessonView: View {
    var body: some View {
        GeometryReader { proxy in
            let cardWidth = max((proxy.size.width - 24) / 2, 420)
            let cardHeight = max(proxy.size.height - 82, 320)
            let dotSize = min(max((cardHeight - 190) / 6.0, 28), 52)
            let dotSpacing = min(max(dotSize * 0.28, 12), 18)

            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 24) {
                    ArrayCard(
                        title: "Example",
                        fact: "3 x 4 = 12",
                        rowsText: "3 rows",
                        eachRowText: "4 dots in each row",
                        color: Color(red: 0.16, green: 0.43, blue: 0.92),
                        rows: 3,
                        columns: 4,
                        dotSize: dotSize + 6,
                        dotSpacing: dotSpacing
                    )
                    .frame(width: cardWidth, height: cardHeight)

                    ArrayCard(
                        title: "Your turn",
                        fact: "5 x 6 = ?",
                        rowsText: "5 rows",
                        eachRowText: "6 dots in each row",
                        color: Color(red: 0.09, green: 0.64, blue: 0.42),
                        rows: 5,
                        columns: 6,
                        dotSize: dotSize,
                        dotSpacing: dotSpacing
                    )
                    .frame(width: cardWidth, height: cardHeight)
                }

                Text("Read the structure first. How many rows? How many dots in each row? Then multiply.")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(red: 0.47, green: 0.24, blue: 0.86))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                    )
            }
        }
    }
}

private struct ArrayCard: View {
    let title: String
    let fact: String
    let rowsText: String
    let eachRowText: String
    let color: Color
    let rows: Int
    let columns: Int
    let dotSize: CGFloat
    let dotSpacing: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(.black.opacity(0.64))
                    Text(fact)
                        .font(.system(size: 35, weight: .black))
                        .foregroundColor(color)
                        .minimumScaleFactor(0.75)
                }
                Spacer()
            }

            Spacer(minLength: 0)

            DotArray(rows: rows, columns: columns, dotSize: dotSize, spacing: dotSpacing, color: color)
                .frame(maxWidth: .infinity, minHeight: dotSize * CGFloat(rows) + dotSpacing * CGFloat(max(rows - 1, 0)) + 12)
                .padding(.vertical, 8)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                LabelPill(text: rowsText, color: color)
                LabelPill(text: eachRowText, color: color)
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.08), radius: 18, y: 10)
        )
    }
}

private struct DotArray: View {
    let rows: Int
    let columns: Int
    let dotSize: CGFloat
    let spacing: CGFloat
    let color: Color

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { _ in
                        Circle()
                            .fill(color)
                            .frame(width: dotSize, height: dotSize)
                            .shadow(color: color.opacity(0.35), radius: 8)
                    }
                }
            }
        }
    }
}

private struct LabelPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(Capsule().fill(color))
    }
}

private struct FractionBarLessonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("One whole")
                .font(.system(size: 30, weight: .bold))
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.16, green: 0.43, blue: 0.92))
                .frame(height: 90)

            Text("Three of four equal parts")
                .font(.system(size: 30, weight: .bold))
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    Rectangle()
                        .fill(index < 3 ? Color(red: 0.09, green: 0.64, blue: 0.42) : Color.white)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 3))
                }
            }
            .frame(height: 130)

            Text("Where is three fourths?")
                .font(.system(size: 32, weight: .black))
                .foregroundColor(Color(red: 0.47, green: 0.24, blue: 0.86))
        }
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white))
    }
}

private struct DerivativeSlopeLessonView: View {
    var body: some View {
        Canvas { context, size in
            let ink = Color.black.opacity(0.82)
            var axis = Path()
            axis.move(to: CGPoint(x: 90, y: size.height - 90))
            axis.addLine(to: CGPoint(x: size.width - 90, y: size.height - 90))
            axis.move(to: CGPoint(x: 90, y: size.height - 90))
            axis.addLine(to: CGPoint(x: 90, y: 80))
            context.stroke(axis, with: .color(ink), lineWidth: 5)

            var curve = Path()
            curve.move(to: CGPoint(x: 110, y: size.height - 120))
            curve.addCurve(
                to: CGPoint(x: size.width - 150, y: 130),
                control1: CGPoint(x: size.width * 0.32, y: size.height - 140),
                control2: CGPoint(x: size.width * 0.62, y: 70)
            )
            context.stroke(curve, with: .color(Color(red: 0.16, green: 0.43, blue: 0.92)), lineWidth: 8)

            var tangent = Path()
            tangent.move(to: CGPoint(x: size.width * 0.42, y: size.height * 0.58))
            tangent.addLine(to: CGPoint(x: size.width * 0.75, y: size.height * 0.28))
            context.stroke(tangent, with: .color(Color(red: 0.93, green: 0.42, blue: 0.16)), lineWidth: 8)
        }
        .overlay(alignment: .bottom) {
            Text("The derivative is the slope right here.")
                .font(.system(size: 34, weight: .black))
                .foregroundColor(Color(red: 0.93, green: 0.42, blue: 0.16))
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.92)))
                .padding(.bottom, 22)
        }
    }
}

private struct ConceptMapLessonView: View {
    let title: String

    var body: some View {
        VStack(spacing: 30) {
            Text(title)
                .font(.system(size: 40, weight: .black))
            HStack(spacing: 30) {
                LabelPill(text: "Part", color: Color(red: 0.16, green: 0.43, blue: 0.92))
                LabelPill(text: "Relationship", color: Color(red: 0.09, green: 0.64, blue: 0.42))
                LabelPill(text: "Change", color: Color(red: 0.93, green: 0.42, blue: 0.16))
            }
            Text("What connects these ideas?")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(Color(red: 0.47, green: 0.24, blue: 0.86))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white))
    }
}
