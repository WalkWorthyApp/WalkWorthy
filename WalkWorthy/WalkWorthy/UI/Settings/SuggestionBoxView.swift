//
//  SuggestionBoxView.swift
//  WalkWorthy
//
//  Settings → About → Send a Suggestion. Free-text feedback stored by the
//  `suggestion` Cloud Function for the developer to read; nothing here is
//  sent to the AI provider.
//

import SwiftUI

struct SuggestionBoxView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// One ID per draft. Resending an unchanged draft after a failure reuses
    /// it, so a request that reached the server before its response was lost
    /// is stored once; editing the draft starts a new one.
    @State private var draftID = UUID()
    @State private var category: SuggestionRequest.Category = .idea
    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var didSend = false

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Unicode scalars, matching the backend's code-point limit.
    private var length: Int { trimmedText.unicodeScalars.count }
    private var isTooLong: Bool { length > SuggestionRequest.maxLength }
    private var canSend: Bool { !trimmedText.isEmpty && !isTooLong && !isSending }

    var body: some View {
        NavigationStack {
            ZStack {
                TimeOfDayTheme.current.backdrop
                    .ignoresSafeArea()

                if didSend {
                    thankYou
                } else {
                    form
                }
            }
            .navigationTitle("Suggestion Box")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if didSend {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isSending)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSending {
                            ProgressView()
                        } else {
                            Button("Send") { Task { await send() } }
                                .disabled(!canSend)
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSending)
        .onChange(of: text) { draftID = UUID() }
        .onChange(of: category) { draftID = UUID() }
    }

    private var form: some View {
        Form {
            Section {
                // Segmented, not a menu: the iOS 26 menu's glass morph is a
                // large expansion that dropped frames over this sheet.
                Picker("Type", selection: $category) {
                    ForEach(SuggestionRequest.Category.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.wwCardBackground)
            }

            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("What would make WalkWorthy better for you?")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Suggestion")
                    .listRowBackground(Color.wwCardBackground)
            } footer: {
                HStack {
                    Spacer()
                    Text("\(length) / \(SuggestionRequest.maxLength)")
                        .monospacedDigit()
                        .foregroundStyle(isTooLong ? Color.red : Color.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.wwCardBackground)
                }
            }

            Section {
                Text("Please don't include personal or sensitive details. Suggestions are read by the developer and aren't monitored for emergencies; in the U.S., call or text 988 for crisis support. For help with your account, use Contact Support.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .disabled(isSending)
    }

    private var thankYou: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Thank you!")
                .font(.title2.weight(.semibold))
            Text("Your suggestion was sent. We read every one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func send() async {
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        let request = SuggestionRequest(
            id: draftID.uuidString,
            category: category,
            text: trimmedText,
            appVersion: Bundle.main.versionString
        )
        do {
            try await appState.submitSuggestion(request)
            didSend = true
        } catch is CancellationError {
            return
        } catch APIError.rateLimited(_, _) {
            errorMessage = "You've sent several suggestions today. Please try again tomorrow."
        } catch {
            errorMessage = "Your suggestion couldn't be sent. Check your connection and try again."
        }
    }
}
