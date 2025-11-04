//
//  HomeView.swift
//  WalkWorthy
//
//  Primary verse feed with navigation controls.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                translationMenu

                VerseCard(verse: appState.currentVerse, selectedTranslation: appState.selectedTranslation)
                    .overlay(alignment: .bottomLeading) {
                        if !appState.hasFreshEncouragement {
                            encouragementOverlay
                        }
                    }

                controlButtons

                statusCard

                CanvasLinkView()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 120)
        }
        .background(backgroundGradient)
        .navigationTitle("Today’s Encouragement")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $appState.showPopups) {
            EncouragementPopupsView(cards: MockData.encouragementCards) {
                appState.dismissPopups()
            }
        }
    }

    private var encouragementOverlay: some View {
        let message = appState.encouragementStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "You’re all caught up for now."
        return HStack {
            Spacer(minLength: 0)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
    }

    private var translationMenu: some View {
        HStack {
            Menu {
                ForEach(Translation.allCases) { translation in
                    Button {
                        appState.setTranslation(translation)
                    } label: {
                        if translation == appState.selectedTranslation {
                            Label(translation.displayName, systemImage: "checkmark")
                        } else {
                            Text(translation.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Translation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Text(appState.selectedTranslation.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }

                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            }

            Spacer()
        }
    }

    private var controlButtons: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Button(action: appState.goToPreviousVerse) {
                    Label("Previous", systemImage: "chevron.left")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())

                Button(action: appState.goToNextVerse) {
                    Label("Next", systemImage: "chevron.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
            }

            Button {
                appState.triggerScanNow()
            } label: {
                Group {
                    if appState.isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Scanning…")
                        }
                    } else {
                        Label("Scan Now", systemImage: "arrow.clockwise.circle")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassAccentButtonStyle())
            .disabled(appState.isScanning)

            Button {
                appState.presentPopups()
            } label: {
                Label("Show Pop-ups", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = appState.latestScanError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            } else {
                if let summary = appState.latestScanSummary {
                    Label(summary.status == .success ? "Fresh encouragement" : "Fallback encouragement", systemImage: summary.status == .success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(summary.status == .success ? Color.green : Color.orange)

                    HStack(spacing: 12) {
                        metricView(title: "Planner", value: summary.plannerCount)
                        metricView(title: "Stressful", value: summary.stressfulCount)
                        metricView(title: "Candidates", value: summary.candidateCount)
                    }

                    if let tags = summary.tags, !tags.isEmpty {
                        Text("Tags: \(tags.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = appState.encouragementStatusMessage {
                    statusMessageLabel(for: message)
                } else if appState.latestScanSummary == nil {
                    Text("Tap Scan Now to refresh today’s encouragement.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private func metricView(title: String, value: Int?) -> some View {
        VStack(spacing: 4) {
            Text("\(value ?? 0)")
                .font(.headline)
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusMessageLabel(for message: String) -> some View {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "Scan for new encouragement." {
            return AnyView(
                HStack {
                    Spacer(minLength: 0)
                    Text(normalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
            )
        } else {
            return AnyView(
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
            )
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color(.systemBlue).opacity(0.1), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.3 : 0.15), lineWidth: 1)
            )
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private struct GlassAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(Color.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 14, x: 0, y: 10)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
