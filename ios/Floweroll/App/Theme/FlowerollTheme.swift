import Foundation
import Observation
import SwiftUI

struct FlowerollThemePalette: Equatable, Sendable {
    let accentRGB: UInt32
    let strongAccentRGB: UInt32
    let onStrongAccentRGB: UInt32

    var accent: Color { Color(flowerollRGB: accentRGB) }
    var strongAccent: Color { Color(flowerollRGB: strongAccentRGB) }
    var onStrongAccent: Color { Color(flowerollRGB: onStrongAccentRGB) }
}

enum FlowerollAccentChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case blush
    case rose
    case coral
    case lavender
    case sky
    case mint

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blush: return "浅粉"
        case .rose: return "玫瑰"
        case .coral: return "珊瑚"
        case .lavender: return "薰衣草"
        case .sky: return "天空"
        case .mint: return "薄荷"
        }
    }

    var palette: FlowerollThemePalette {
        switch self {
        case .blush:
            return FlowerollThemePalette(
                accentRGB: 0xE78BB2,
                strongAccentRGB: 0xC34A7A,
                onStrongAccentRGB: 0xFFFFFF
            )
        case .rose:
            return FlowerollThemePalette(
                accentRGB: 0xD96C98,
                strongAccentRGB: 0xA83265,
                onStrongAccentRGB: 0xFFFFFF
            )
        case .coral:
            return FlowerollThemePalette(
                accentRGB: 0xE58A78,
                strongAccentRGB: 0xA94435,
                onStrongAccentRGB: 0xFFFFFF
            )
        case .lavender:
            return FlowerollThemePalette(
                accentRGB: 0xB6A1E4,
                strongAccentRGB: 0x66509C,
                onStrongAccentRGB: 0xFFFFFF
            )
        case .sky:
            return FlowerollThemePalette(
                accentRGB: 0x7DB7E8,
                strongAccentRGB: 0x2D6C9F,
                onStrongAccentRGB: 0xFFFFFF
            )
        case .mint:
            return FlowerollThemePalette(
                accentRGB: 0x73C8A9,
                strongAccentRGB: 0x24745E,
                onStrongAccentRGB: 0xFFFFFF
            )
        }
    }
}

@MainActor
@Observable
final class FlowerollThemeStore {
    nonisolated static let defaultsKey = "floweroll.theme.accent.v1"
    nonisolated static let defaultChoice: FlowerollAccentChoice = .blush

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var choice: FlowerollAccentChoice

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persisted = defaults.string(forKey: Self.defaultsKey)
        let resolved = persisted.flatMap(FlowerollAccentChoice.init(rawValue:)) ?? Self.defaultChoice
        self.choice = resolved

        if persisted != resolved.rawValue {
            defaults.set(resolved.rawValue, forKey: Self.defaultsKey)
        }
    }

    var palette: FlowerollThemePalette { choice.palette }

    func select(_ choice: FlowerollAccentChoice) {
        guard self.choice != choice else { return }
        self.choice = choice
        defaults.set(choice.rawValue, forKey: Self.defaultsKey)
    }
}

private struct FlowerollThemePaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue = FlowerollThemeStore.defaultChoice.palette
}

extension EnvironmentValues {
    var flowerollThemePalette: FlowerollThemePalette {
        get { self[FlowerollThemePaletteEnvironmentKey.self] }
        set { self[FlowerollThemePaletteEnvironmentKey.self] = newValue }
    }
}

private extension Color {
    init(flowerollRGB value: UInt32) {
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
