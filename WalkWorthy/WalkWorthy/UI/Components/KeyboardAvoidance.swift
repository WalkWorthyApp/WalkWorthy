//
//  KeyboardAvoidance.swift
//  WalkWorthy
//
//  Shared keyboard handling for screens with text entry.
//
//  The pattern every form screen follows:
//  - Text entry lives inside a scroll container, so when the keyboard shrinks
//    the safe area the content moves up instead of being covered.
//    `Form`/`List` screens get this (and focused-row scrolling) from the system.
//  - `ScrollView` screens also add `.scrollDismissesKeyboard(.interactively)`
//    and `.keepsFocusedFieldVisible(_:in:)`, tagging each field's container
//    with `.id(<focus value>)`, so the field being typed in is scrolled clear
//    of the keyboard once it is up and whenever focus moves.
//

import SwiftUI
import Combine

extension View {
    /// Scrolls the view tagged `.id(focus)` into the visible area of the
    /// enclosing `ScrollViewReader`'s scroll view when focus changes and after
    /// the keyboard finishes appearing (when the scroll view has its final,
    /// keyboard-shrunk size).
    func keepsFocusedFieldVisible<Field: Hashable>(
        _ focus: Field?,
        in proxy: ScrollViewProxy,
        anchor: UnitPoint = .center
    ) -> some View {
        modifier(KeepsFocusedFieldVisible(focus: focus, proxy: proxy, anchor: anchor))
    }
}

private struct KeepsFocusedFieldVisible<Field: Hashable>: ViewModifier {
    let focus: Field?
    let proxy: ScrollViewProxy
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .onChange(of: focus) { scrollToFocusedField() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                scrollToFocusedField()
            }
    }

    private func scrollToFocusedField() {
        guard let focus else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(focus, anchor: anchor)
        }
    }
}
