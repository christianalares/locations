import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import CoreText
#endif

public extension Color {
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        let lightColor = UIColor(light)
        let darkColor = UIColor(dark)
        self = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
        #elseif canImport(AppKit)
        let lightColor = NSColor(light)
        let darkColor = NSColor(dark)
        self = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? darkColor
                : lightColor
        })
        #else
        self = light
        #endif
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

public enum BlipColor {
    public static let background = Color(
        light: Color(hex: 0xFBF8F5),
        dark: Color(hex: 0x181817)
    )
    public static let sidebar = Color(
        light: Color(hex: 0xF0EAE6),
        dark: Color(hex: 0x20201F)
    )
    public static let surface = Color(
        light: Color(hex: 0xFFFDFB),
        dark: Color(hex: 0x242321)
    )
    public static let surfaceSoft = Color(
        light: Color(hex: 0xF5EFEB),
        dark: Color(hex: 0x2C2A28)
    )
    public static let surfaceStrong = Color(
        light: Color(hex: 0xE9DFDA),
        dark: Color(hex: 0x373431)
    )
    public static let textPrimary = Color(
        light: Color(hex: 0x211A1F),
        dark: Color(hex: 0xFCF8F3)
    )
    public static let textSecondary = Color(
        light: Color(hex: 0x766B72),
        dark: Color(hex: 0xC5BDB6)
    )
    public static let textTertiary = Color(
        light: Color(hex: 0x9A8F95),
        dark: Color(hex: 0x99918A)
    )
    public static let hairline = Color(
        light: Color(hex: 0x4A3B33, opacity: 0.11),
        dark: Color(hex: 0xFFF6EE, opacity: 0.07)
    )
    public static let hairlineHover = Color(
        light: Color(hex: 0x4A3B33, opacity: 0.17),
        dark: Color(hex: 0xFFF6EE, opacity: 0.12)
    )
    public static let orange = Color(
        light: Color(hex: 0xF06E3B),
        dark: Color(hex: 0xFF824F)
    )
    public static let orangeText = Color(
        light: Color(hex: 0xC45129),
        dark: Color(hex: 0xFFA27B)
    )
    public static let orangeSoft = Color(
        light: Color(hex: 0xF06E3B, opacity: 0.09),
        dark: Color(hex: 0xFF824F, opacity: 0.12)
    )
    public static let mentionBackground = Color(
        light: Color(hex: 0xF06E3B, opacity: 0.11),
        dark: Color(hex: 0xFF824F, opacity: 0.16)
    )
    public static let mentionBorder = Color(
        light: Color(hex: 0x000000, opacity: 0.10),
        dark: Color(hex: 0xFFFFFF, opacity: 0.10)
    )
    public static let userMessage = Color(
        light: Color(hex: 0xF06E3B, opacity: 0.09),
        dark: Color(hex: 0x2F2F2F)
    )
    public static let neutralAnchor = Color(
        light: Color(hex: 0x3A302B),
        dark: Color(hex: 0x3B3632)
    )
    public static let glow = Color(hex: 0xFFD66F)
    public static let warning = Color(
        light: Color(hex: 0xA85732),
        dark: Color(hex: 0xF0A374)
    )
    public static let success = Color(
        light: Color(hex: 0x38735D),
        dark: Color(hex: 0x76B99B)
    )
    public static let device = Color(
        light: Color(hex: 0x4D7397),
        dark: Color(hex: 0x91B9DD)
    )
    public static let devBlue = Color(hex: 0x3E7DB9)
}

#if os(iOS)
enum BlipIOSHeaderControlMetrics {
    static let diameter: CGFloat = 36
    static let iconSize: CGFloat = 14
    static let itemSpacing: CGFloat = 8
    static let tabIndicatorDiameter = diameter - 4
}

private struct BlipIOSHeaderControlModifier: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .frame(
                width: BlipIOSHeaderControlMetrics.diameter,
                height: BlipIOSHeaderControlMetrics.diameter
            )
            .background(
                isSelected
                    ? BlipColor.surfaceStrong.opacity(0.82)
                    : BlipColor.surface.opacity(0.72),
                in: Circle()
            )
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay {
                Circle()
                    .stroke(BlipColor.hairlineHover, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Circle())
    }
}

extension View {
    func blipIOSHeaderControl(isSelected: Bool = false) -> some View {
        modifier(BlipIOSHeaderControlModifier(isSelected: isSelected))
    }
}
#endif

public struct BlipAppBackground: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init() {}

    public var body: some View {
        Group {
            if colorSchemeContrast == .increased {
                BlipColor.background
            } else {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        SIMD2<Float>(0, 0), SIMD2<Float>(0.43, 0), SIMD2<Float>(1, 0),
                        SIMD2<Float>(0, 0.46), SIMD2<Float>(0.58, 0.48), SIMD2<Float>(1, 0.52),
                        SIMD2<Float>(0, 1), SIMD2<Float>(0.47, 1), SIMD2<Float>(1, 1),
                    ],
                    colors: [
                        BlipColor.background, Self.peach, BlipColor.background,
                        Self.rose, BlipColor.background, Self.gold,
                        BlipColor.background, Self.mist, BlipColor.background,
                    ],
                    background: BlipColor.background,
                    smoothsColors: true,
                    colorSpace: .perceptual
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static let peach = Color(
        light: Color(hex: 0xFFF0E8),
        dark: Color(hex: 0x251D19)
    )
    private static let gold = Color(
        light: Color(hex: 0xFFF7DF),
        dark: Color(hex: 0x242018)
    )
    private static let rose = Color(
        light: Color(hex: 0xF8EEF1),
        dark: Color(hex: 0x211B20)
    )
    private static let mist = Color(
        light: Color(hex: 0xEEF4F1),
        dark: Color(hex: 0x1A2020)
    )
}

public enum BlipFont {
    private static let headingRegularName = "BricolageGrotesque-Regular"
    private static let headingMediumName = "BricolageGrotesque-Medium"
    private static let headingSemiboldName = "BricolageGrotesque-SemiBold"
    private static let headingBoldName = "BricolageGrotesque-Bold"
    private static let headingExtraBoldName = "BricolageGrotesque-ExtraBold"

    public static func character(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    public static func heading(
        _ size: CGFloat,
        weight: Font.Weight = .semibold,
        relativeTo textStyle: Font.TextStyle = .headline
    ) -> Font {
        .custom(
            headingName(for: weight),
            size: size,
            relativeTo: textStyle
        )
    }

    #if os(macOS)
    public static func configureMacTypography() {
        guard let fontURL = Bundle.main.url(
            forResource: "BricolageGrotesque",
            withExtension: "ttf"
        ) else { return }

        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }
    #endif

    #if os(iOS)
    @MainActor
    public static func configureIOSNavigationTypography() {
        let navigationBar = UINavigationBar.appearance()
        navigationBar.largeTitleTextAttributes = [
            .font: uiHeading(size: 34, weight: .bold, relativeTo: .largeTitle),
        ]
        navigationBar.titleTextAttributes = [
            .font: uiHeading(size: 17, weight: .semibold, relativeTo: .headline),
        ]
    }

    #endif

    private static func headingName(for weight: Font.Weight) -> String {
        if weight == .black || weight == .heavy {
            return headingExtraBoldName
        }
        if weight == .bold {
            return headingBoldName
        }
        if weight == .semibold {
            return headingSemiboldName
        }
        if weight == .medium {
            return headingMediumName
        }
        return headingRegularName
    }

    #if os(iOS)
    private static func uiHeading(
        size: CGFloat,
        weight: UIFont.Weight,
        relativeTo textStyle: UIFont.TextStyle
    ) -> UIFont {
        let name: String
        if weight >= .heavy {
            name = headingExtraBoldName
        } else if weight >= .bold {
            name = headingBoldName
        } else if weight >= .semibold {
            name = headingSemiboldName
        } else if weight >= .medium {
            name = headingMediumName
        } else {
            name = headingRegularName
        }
        let baseFont = UIFont(name: name, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: baseFont)
    }
    #endif
}

public enum BlipRadius {
    public static let control: CGFloat = 8
    public static let message: CGFloat = 14
    public static let card: CGFloat = 12
    public static let composer: CGFloat = 14
}
