import AppKit

/// 候选窗排列方式
enum CandidateLayout: Equatable {
    case horizontal          // 横排一行（默认，每页 8 个）
    case vertical            // 竖排一列
    case grid(columns: Int)  // 按 ↓ 展开后的多行多列（7 × 7）
}

/// 候选窗要显示的内容
struct CandidateDisplay {
    var header: String = ""
    var items: [Candidate] = []
    /// 每个候选前面的序号（空字符串表示不显示）
    var labels: [String] = []
    var highlighted: Int = 0
    var layout: CandidateLayout = .horizontal
    /// 底部提示（展开时显示操作说明）
    var footer: String = ""
}

/// 候选窗：显示在光标下方，支持横排、竖排、展开的多行多列，支持鼠标点选
@MainActor
final class CandidatePanel {
    private let panel: NSPanel
    private let view = CandidateView()
    /// 点了第几个（items 里的下标）
    var onSelect: ((Int) -> Void)? {
        get { view.onSelect }
        set { view.onSelect = newValue }
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = view
    }

    func show(_ display: CandidateDisplay, caret: NSRect) {
        guard !display.header.isEmpty || !display.items.isEmpty else {
            hide()
            return
        }
        view.display = display
        let size = view.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelPlacement.origin(below: caret, size: size))
        panel.orderFrontRegardless()
        view.needsDisplay = true
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// 计算浮窗位置：放在光标下方，放不下就放上方，并保证在屏幕内
@MainActor
enum PanelPlacement {
    static func origin(below caret: NSRect, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = caret.minX
        var y = caret.minY - size.height - 4
        if y < visible.minY { y = caret.maxY + 4 }
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}

final class CandidateView: NSView {
    var display = CandidateDisplay() { didSet { layoutCandidates() } }
    var onSelect: ((Int) -> Void)?

    private let padding: CGFloat = 8
    private var rects: [NSRect] = []
    private var headerHeight: CGFloat = 0
    private var footerHeight: CGFloat = 0
    private var contentSize = NSSize(width: 160, height: 30)

    private var candidateFont: NSFont { .systemFont(ofSize: 17) }
    private var labelFont: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .regular) }
    private var commentFont: NSFont { .systemFont(ofSize: 12) }
    private var headerFont: NSFont { .systemFont(ofSize: 13) }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { contentSize }

    private func attributed(_ index: Int) -> NSAttributedString {
        let candidate = display.items[index]
        let result = NSMutableAttributedString()
        let label = index < display.labels.count ? display.labels[index] : ""
        let highlighted = index == display.highlighted
        if !label.isEmpty {
            result.append(NSAttributedString(string: label + " ", attributes: [
                .font: labelFont,
                .foregroundColor: highlighted ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor,
            ]))
        }
        result.append(NSAttributedString(string: candidate.text, attributes: [
            .font: candidateFont,
            .foregroundColor: highlighted ? NSColor.white : NSColor.labelColor,
        ]))
        // 横排和展开时不显示拼音注释（太宽），竖排显示
        if display.layout == .vertical, let comment = candidate.comment {
            result.append(NSAttributedString(string: "  " + comment, attributes: [
                .font: commentFont,
                .foregroundColor: highlighted ? NSColor.white.withAlphaComponent(0.8) : NSColor.tertiaryLabelColor,
            ]))
        }
        return result
    }

    private func layoutCandidates() {
        rects = []
        var y = padding
        var width: CGFloat = 80
        if !display.header.isEmpty {
            let size = (display.header as NSString).size(withAttributes: [.font: headerFont])
            headerHeight = ceil(size.height) + 4
            width = max(width, ceil(size.width))
            y += headerHeight
        } else {
            headerHeight = 0
        }
        let sizes = display.items.indices.map { attributed($0).size() }
        let rowHeight = ceil((sizes.map(\.height).max() ?? 20)) + 6

        switch display.layout {
        case .horizontal:
            var x = padding - 4
            for size in sizes {
                let rect = NSRect(x: x, y: y, width: ceil(size.width) + 12, height: rowHeight)
                rects.append(rect)
                x += rect.width + 4
            }
            width = max(width, x - padding)
            y += rowHeight
        case .vertical:
            let cellWidth = max(width, (sizes.map(\.width).max() ?? 40) + 12)
            for _ in sizes {
                rects.append(NSRect(x: padding - 4, y: y, width: cellWidth + 8, height: rowHeight))
                y += rowHeight + 2
            }
            width = cellWidth
        case .grid(let columns):
            let cellWidth = max(56, ceil(sizes.map(\.width).max() ?? 40) + 14)
            for (i, _) in sizes.enumerated() {
                let row = i / columns, col = i % columns
                rects.append(NSRect(x: padding - 4 + CGFloat(col) * (cellWidth + 4),
                                    y: y + CGFloat(row) * (rowHeight + 2),
                                    width: cellWidth, height: rowHeight))
            }
            let rows = (sizes.count + columns - 1) / max(columns, 1)
            width = max(width, CGFloat(min(columns, sizes.count)) * (cellWidth + 4) - 4)
            y += CGFloat(rows) * (rowHeight + 2)
        }
        if !display.footer.isEmpty {
            let size = (display.footer as NSString).size(withAttributes: [.font: commentFont])
            footerHeight = ceil(size.height) + 6
            width = max(width, ceil(size.width))
            y += footerHeight
        } else {
            footerHeight = 0
        }
        contentSize = NSSize(width: ceil(width + padding * 2), height: ceil(y + padding))
        frame.size = contentSize
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.lineWidth = 1
        background.stroke()

        if !display.header.isEmpty {
            (display.header as NSString).draw(at: NSPoint(x: padding, y: padding - 2), withAttributes: [
                .font: headerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        for (index, rect) in rects.enumerated() {
            if index == display.highlighted {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let text = attributed(index)
            let size = text.size()
            let x = display.layout == .vertical ? rect.minX + 6 : rect.midX - size.width / 2
            text.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2))
        }
        if !display.footer.isEmpty {
            (display.footer as NSString).draw(at: NSPoint(x: padding, y: bounds.height - padding - footerHeight + 4), withAttributes: [
                .font: commentFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = rects.firstIndex(where: { $0.contains(point) }) {
            onSelect?(index)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
