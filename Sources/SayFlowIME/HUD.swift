import AppKit

/// 屏幕下方的提示条（不抢焦点、不接收鼠标）
@MainActor
final class HUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    func show(_ text: String, duration: TimeInterval? = 2.5) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = text
        let width = min(max(label.intrinsicContentSize.width + 48, 180), 640)
        let height: CGFloat = 44
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 80, width: width, height: height),
                           display: true)
        }
        panel.orderFrontRegardless()
        generation += 1
        let current = generation
        if let duration {
            after(duration) { [weak self] in
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    func hide() {
        generation += 1
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 16),
        ])
        panel.contentView = background
        return panel
    }
}
