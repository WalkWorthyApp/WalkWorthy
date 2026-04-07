//
//  Font+Newsreader.swift
//  WalkWorthy
//
//  Convenience wrappers for the Newsreader serif font,
//  used for spiritual headers and verse text throughout the app.
//

import SwiftUI

extension Font {
    /// Newsreader at a fixed point size. Defaults to italic, which is the
    /// primary editorial voice in the design system. Uses fixedSize so the
    /// design-system sizing is preserved regardless of accessibility settings.
    static func newsreader(fixedSize size: CGFloat, italic: Bool = true) -> Font {
        let name = italic ? "Newsreader-Italic" : "Newsreader-Regular"
        return .custom(name, fixedSize: size)
    }

    /// Newsreader Semi-Bold Italic — for verse references and section headers.
    /// Always italic; only the SemiBoldItalic weight is bundled.
    static func newsreaderSemiBoldItalic(fixedSize size: CGFloat) -> Font {
        .custom("Newsreader-SemiBoldItalic", fixedSize: size)
    }
}
