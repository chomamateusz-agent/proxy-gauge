import SwiftUI

extension Font {
    // macOS text styles run two to four points smaller than iOS and ignore dynamic type, so the shared cards step one style up there.
    static func board(_ style: Font.TextStyle) -> Font {
        #if os(macOS)
        switch style {
        case .largeTitle: .system(size: 30)
        case .title: .largeTitle
        case .title2: .title
        case .title3: .title2
        case .headline: .system(.title3, weight: .semibold)
        case .subheadline, .callout: .body
        case .footnote: .callout
        case .caption: .subheadline
        case .caption2: .footnote
        default: .system(style)
        }
        #else
        .system(style)
        #endif
    }

    static func board(_ style: Font.TextStyle, design: Font.Design) -> Font {
        #if os(macOS)
        style == .largeTitle ? .system(size: 30, design: design) : board(style)
        #else
        .system(style, design: design)
        #endif
    }
}
