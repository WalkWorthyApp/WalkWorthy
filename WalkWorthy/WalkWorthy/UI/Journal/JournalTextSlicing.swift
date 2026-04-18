//
//  JournalTextSlicing.swift
//  WalkWorthy
//
//  Pure helpers for deriving Apple Notes-style title/preview from a
//  JournalEntry's `text` field, and for projecting that single string
//  into two bindings in the editor.
//

import Foundation

enum JournalTextSlicing {
    struct TitleAndPreview: Equatable { let title: String; let preview: String }
    struct EditorSplit: Equatable   { let title: String; let body: String }

    /// For list rows: first non-empty line = title, second non-empty line = preview.
    /// Blank lines are skipped.
    static func titleAndPreview(from text: String) -> TitleAndPreview {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let title = lines.first ?? ""
        let preview = lines.dropFirst().first ?? ""
        return .init(title: title, preview: preview)
    }

    /// For the editor: split `text` at the first `\n`.
    /// The title binding reads/writes the prefix; the body binding the suffix.
    static func editorSplit(_ text: String) -> EditorSplit {
        guard let firstNewline = text.firstIndex(of: "\n") else {
            return .init(title: text, body: "")
        }
        let title = String(text[..<firstNewline])
        let body = String(text[text.index(after: firstNewline)...])
        return .init(title: title, body: body)
    }

    /// Inverse of `editorSplit`: reconstruct `text` from the two editor fields.
    static func editorJoin(title: String, body: String) -> String {
        body.isEmpty ? title : "\(title)\n\(body)"
    }
}
