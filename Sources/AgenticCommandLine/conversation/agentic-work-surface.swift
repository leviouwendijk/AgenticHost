import Terminal

/// Pure terminal presentation for the Agentic Work dashboard, Agent selection,
/// and application quit sheet. The Host owns sessions and command handling.
public enum AgenticWorkSurface {
    public enum Tone: Sendable, Hashable {
        case neutral
        case running
        case attention
        case new
    }

    public struct Pad: Sendable, Hashable {
        public var title: String
        public var primary: String
        public var secondary: String
        public var hint: String
        public var tone: Tone

        public init(
            title: String,
            primary: String,
            secondary: String,
            hint: String,
            tone: Tone = .neutral
        ) {
            self.title = title
            self.primary = primary
            self.secondary = secondary
            self.hint = hint
            self.tone = tone
        }
    }

    /// A responsive, scroll-following gallery of rounded selectable pads.
    /// Index identity comes from the caller; this type never owns sessions.
    public static func renderGallery(
        into frame: inout TerminalFrame,
        in region: TerminalRegion,
        section: String,
        subtitle: String,
        summary: String,
        pads: [Pad],
        selectedIndex: Int,
        footer: String,
        commandLine: TerminalCommandLine,
        notice: String? = nil
    ) {
        guard !region.isEmpty else { return }
        let canvas = centered(in: region, maximumColumns: 112)
        guard canvas.columns > 0 else { return }
        let headline = TerminalStyle(.bold, .brightCyan).apply("AGENTIC")
            + TerminalStyle.dim.apply("  /  WORK")
        line(headline, row: canvas.top, frame: &frame, in: canvas)
        line(
            TerminalStyle.bold.apply(section.uppercased())
                + TerminalStyle.dim.apply("   " + summary),
            row: canvas.top + 2,
            frame: &frame,
            in: canvas
        )
        line(
            TerminalStyle.dim.apply(subtitle),
            row: canvas.top + 3,
            frame: &frame,
            in: canvas
        )

        let gridTop = canvas.top + 5
        let footerRows = 3
        let gridRows = max(0, canvas.bottom - gridTop - footerRows)
        let columnCount = canvas.columns >= 82 ? 2 : 1
        let columnGap = columnCount == 2 ? 3 : 0
        let cardWidth = max(0, (canvas.columns - columnGap) / columnCount)
        let rowStride = 7
        let visibleGridRows = max(1, gridRows / rowStride)
        let selected = min(max(0, selectedIndex), max(0, pads.count - 1))
        let firstGridRow = max(0, selected / columnCount - visibleGridRows + 1)
        let lastGridRow = firstGridRow + visibleGridRows

        for (index, pad) in pads.enumerated() {
            let gridRow = index / columnCount
            guard gridRow >= firstGridRow, gridRow < lastGridRow else { continue }
            let gridColumn = index % columnCount
            let leading = canvas.leading + gridColumn * (cardWidth + columnGap)
            let top = gridTop + (gridRow - firstGridRow) * rowStride
            let availableRows = max(0, min(rowStride - 1, canvas.bottom - footerRows - top))
            guard availableRows > 0, cardWidth > 0 else { continue }

            let contentWidth = max(1, cardWidth - 6)
            let block = TerminalInteractiveBlock(
                title: TerminalDisplay.clipped(pad.title, columns: max(1, cardWidth - 4)),
                body: TerminalDisplay.clipped(pad.primary, columns: contentWidth)
                    + "\n" + TerminalDisplay.clipped(pad.secondary, columns: contentWidth),
                hint: TerminalDisplay.clipped(pad.hint, columns: contentWidth),
                state: TerminalInteractiveBlock.resolvedState(isFocused: index == selected),
                style: style(for: pad.tone),
                horizontalPadding: cardWidth >= 30 ? 2 : 1
            )
            block.render(
                into: &frame,
                in: TerminalRegion(
                    top: top,
                    leading: leading,
                    rows: availableRows,
                    columns: cardWidth
                )
            )
        }

        if pads.isEmpty {
            line(
                TerminalStyle.dim.apply("Nothing to select."),
                row: gridTop,
                frame: &frame,
                in: canvas
            )
        }
        let totalRows = max(1, (pads.count + columnCount - 1) / columnCount)
        let page = "\(min(totalRows, firstGridRow + 1))–\(min(totalRows, lastGridRow)) / \(totalRows) rows"
        let footerTop = max(gridTop, canvas.bottom - footerRows)
        line(
            TerminalStyle.dim.apply(page + "   " + footer),
            row: footerTop,
            frame: &frame,
            in: canvas
        )
        if let notice, !notice.isEmpty {
            line(TerminalStyle(.yellow).apply(notice), row: footerTop + 1, frame: &frame, in: canvas)
        }
        commandLine.render(
            into: &frame,
            in: TerminalRegion(
                top: canvas.bottom - 1,
                leading: canvas.leading,
                rows: 1,
                columns: canvas.columns
            )
        )
    }

    /// A truly modal, rounded confirmation. The destructive choice is never
    /// initially selected. Callers implement the key-to-decision contract.
    public static func renderQuit(
        into frame: inout TerminalFrame,
        in region: TerminalRegion,
        activeOperations: Int,
        confirms: Bool
    ) {
        guard !region.isEmpty else { return }
        let width = min(66, max(0, region.columns - 4))
        guard width > 0 else { return }
        let height = min(region.rows, 12)
        let top = region.top + max(0, (region.rows - height) / 2)
        let leading = region.leading + max(0, (region.columns - width) / 2)
        let shade = TerminalRegion(top: top, leading: leading, rows: height, columns: width)
        frame.write(Array(repeating: String(repeating: " ", count: width), count: height), in: shade, zIndex: .overlay)
        let message = activeOperations == 0
            ? "Close this Agentic Work application?"
            : "\(activeOperations) operation(s) are still running. Exiting ends this process."
        let panel = TerminalInteractiveBlock(
            title: "Quit Agentic Work?",
            body: message,
            hint: "Select an action below. Esc always cancels.",
            style: style(for: activeOperations > 0 ? .attention : .neutral),
            horizontalPadding: 2
        )
        let panelRows = panel.render(width: width).count
        panel.render(
            into: &frame,
            in: TerminalRegion(top: top, leading: leading, rows: min(height, panelRows), columns: width),
            zIndex: .overlay
        )
        let gap = 2
        let actionWidth = max(0, (width - gap) / 2)
        let actionTop = top + panelRows + 1
        guard actionTop + 3 <= top + height else { return }
        TerminalInteractiveBlock(
            title: "Cancel",
            body: "Return to Work",
            state: TerminalInteractiveBlock.resolvedState(isFocused: !confirms),
            style: style(for: .neutral),
            horizontalPadding: 1
        ).render(
            into: &frame,
            in: TerminalRegion(top: actionTop, leading: leading, rows: 3, columns: actionWidth),
            zIndex: .overlay
        )
        TerminalInteractiveBlock(
            title: "Quit application",
            body: "Exit process",
            state: TerminalInteractiveBlock.resolvedState(isFocused: confirms),
            style: style(for: .attention),
            horizontalPadding: 1
        ).render(
            into: &frame,
            in: TerminalRegion(top: actionTop, leading: leading + actionWidth + gap, rows: 3, columns: actionWidth),
            zIndex: .overlay
        )
    }

    public static func renderConversationHeader(
        into frame: inout TerminalFrame,
        in region: TerminalRegion,
        agent: String,
        position: Int,
        count: Int
    ) {
        let heading = TerminalStyle(.bold, .brightCyan).apply(" AGENTIC ")
            + TerminalStyle.dim.apply("/ WORK / ")
            + TerminalStyle.bold.apply(agent)
            + TerminalStyle.dim.apply("   \(position)/\(count)   Ctrl-W sessions  Ctrl-N new  Ctrl-P next")
        line(heading, row: region.top, frame: &frame, in: region)
    }

    private static func centered(in region: TerminalRegion, maximumColumns: Int) -> TerminalRegion {
        let width = min(maximumColumns, max(0, region.columns - 4))
        return TerminalRegion(
            top: region.top + min(1, max(0, region.rows - 1)),
            leading: region.leading + max(0, (region.columns - width) / 2),
            rows: max(0, region.rows - 2),
            columns: width
        )
    }

    private static func line(
        _ value: String,
        row: Int,
        frame: inout TerminalFrame,
        in region: TerminalRegion
    ) {
        guard row >= region.top, row < region.bottom else { return }
        frame.write(
            TerminalDisplay.clipped(value, columns: region.columns),
            in: TerminalRegion(top: row, leading: region.leading, rows: 1, columns: region.columns)
        )
    }

    private static func style(for tone: Tone) -> TerminalInteractiveBlockStyle {
        let resting: TerminalStyle
        switch tone {
        case .neutral: resting = .dim
        case .running: resting = TerminalStyle(.green)
        case .attention: resting = TerminalStyle(.yellow)
        case .new: resting = TerminalStyle(.brightCyan)
        }
        return TerminalInteractiveBlockStyle(
            border: resting,
            focusedBorder: TerminalStyle(.bold, .brightCyan),
            hoveredBorder: TerminalStyle(.brightCyan),
            activeBorder: TerminalStyle(.bold, .brightCyan),
            disabledBorder: .dim,
            title: .bold,
            body: .none,
            hint: .dim,
            disabledContent: .dim
        )
    }
}
