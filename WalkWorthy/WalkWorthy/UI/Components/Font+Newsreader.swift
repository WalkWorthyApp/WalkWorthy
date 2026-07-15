//
//  Font+Newsreader.swift
//  WalkWorthy
//
//  Convenience wrappers for the Newsreader serif font,
//  used for spiritual headers and verse text throughout the app.
//

import SwiftUI

extension Font {
    /// Newsreader at a design-system point size that scales with the user's
    /// Dynamic Type setting (WCAG/ADA: text must respond to system text
    /// size). Defaults to italic, the primary editorial voice. `size` is the
    /// point size at the default (Large) content size; `relativeTo` picks
    /// the system text style whose scaling curve it follows.
    static func newsreader(size: CGFloat, italic: Bool = true, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        let name = italic ? "Newsreader-Italic" : "Newsreader-Regular"
        return .custom(name, size: size, relativeTo: textStyle)
    }

    /// Newsreader Semi-Bold Italic — for verse references and section headers.
    /// Always italic; only the SemiBoldItalic weight is bundled. Scales with
    /// Dynamic Type along the title curve.
    static func newsreaderSemiBoldItalic(size: CGFloat, relativeTo textStyle: Font.TextStyle = .title3) -> Font {
        .custom("Newsreader-SemiBoldItalic", size: size, relativeTo: textStyle)
    }
}
