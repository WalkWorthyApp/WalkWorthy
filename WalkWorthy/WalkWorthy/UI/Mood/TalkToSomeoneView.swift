//
//  TalkToSomeoneView.swift
//  WalkWorthy
//
//  Pushed from the "Need to talk to someone?" link under a very unpleasant
//  check-in. The 988 options live on their own page, rather than inline in
//  the response, so the response stays uncluttered and nobody dials a crisis
//  line by brushing a link. iOS still asks before placing the call.
//

import SwiftUI

struct TalkToSomeoneView: View {
    var body: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: scaled(24)) {
                    VStack(alignment: .leading, spacing: scaled(10)) {
                        Text("You don't have to carry this alone")
                            .font(.newsreaderSemiBoldItalic(size: scaled(28)))
                            .accessibilityAddTraits(.isHeader)
                        Text("The 988 Suicide & Crisis Lifeline is free, confidential and open 24/7. A trained counselor will listen.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    option(
                        title: "Call 988",
                        detail: "Talk with a counselor by phone.",
                        systemImage: "phone.fill",
                        url: "tel://988"
                    )

                    option(
                        title: "Text 988",
                        detail: "Message a counselor if talking feels like too much.",
                        systemImage: "message.fill",
                        url: "sms:988"
                    )

                    Text("If you or someone else is in immediate danger, call 911. Outside the U.S., contact your local emergency services.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, scaled(16))
                .padding(.vertical, scaled(24))
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Talk to someone")
        .toolbarTitleDisplayMode(.inline)
        // The check-in flow hides its bar; this page needs it for Back.
        .toolbar(.visible, for: .navigationBar)
    }

    @ViewBuilder
    private func option(title: String, detail: String, systemImage: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(spacing: scaled(14)) {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: scaled(28))
                    VStack(alignment: .leading, spacing: scaled(4)) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(scaled(18))
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens your phone to contact the 988 Lifeline")
        }
    }
}

#Preview {
    NavigationStack {
        TalkToSomeoneView()
    }
    .preferredColorScheme(.dark)
}
