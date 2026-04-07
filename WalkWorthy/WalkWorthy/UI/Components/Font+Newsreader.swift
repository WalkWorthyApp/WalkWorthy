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
    /// primary editorial voice in the design system.
    static func newsreader(size: CGFloat, italic: Bool = true) -> Font {
        let name = italic ? "Newsreader-Italic" : "Newsreader-Regular"
        return .custom(name, size: size)
    }

    /// Newsreader Semi-Bold Italic — for verse references and emphasis.
    static func newsreaderSemiBold(size: CGFloat) -> Font {
        .custom("Newsreader-SemiBoldItalic", size: size)
    }
}
