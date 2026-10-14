import AppKit

/// The canary in the menu bar.
enum StatusIcon: Equatable {
    /// Outline canary, dimmed.
    case disarmed
    /// Solid canary, standard menu bar colour.
    case armed
    /// Orange canary: there was a dropout you haven't looked at yet.
    case warning
    /// Red canary, feet up.
    case dead

    func image() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = self == .disarmed ? "bird" : "bird.fill"
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dead Air")!
            .withSymbolConfiguration(config)!

        switch self {
        case .disarmed, .armed:
            base.isTemplate = true
            return base
        case .warning:
            return base.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))!
        case .dead:
            let red = base.withSymbolConfiguration(.init(paletteColors: [.systemRed]))!
            let image = NSImage(size: red.size, flipped: false) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                // Belly up.
                context.translateBy(x: 0, y: rect.maxY + rect.minY)
                context.scaleBy(x: 1, y: -1)
                red.draw(in: rect)
                return true
            }
            image.accessibilityDescription = "Dead Air: no audio"
            return image
        }
    }
}
