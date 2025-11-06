//
//  EncouragementPopupsView.swift
//  WalkWorthy
//
//  Carousel of encouragement cards with haptics.
//

import SwiftUI
import UIKit

struct EncouragementPopupsView: View {
    let verses: [Verse]
    var onDismiss: () -> Void

    @State private var index: Int = 0

    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, verse in
                        VStack(alignment: .leading, spacing: 16) {
                            Text(verse.reference)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.2)
                            Text(verse.encouragement)
                                .font(.title3.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verse.text)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color(.systemBackground).opacity(0.92))
                                .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 10)
                        )
                        .padding(.horizontal, 24)
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(height: 360)
                .padding(.bottom, 12)
                .onChange(of: index) { _, _ in
                    impactGenerator.impactOccurred()
                    impactGenerator.prepare()
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                }
            }
            .navigationTitle("Burst of encouragement")
            .toolbarTitleDisplayMode(.inline)
        }
        .onAppear {
            impactGenerator.prepare()
        }
    }

    private var items: [Verse] {
        var seen = Set<Verse>()
        var ordered: [Verse] = []
        for verse in verses {
            if seen.insert(verse).inserted {
                ordered.append(verse)
            }
        }
        if ordered.isEmpty {
            ordered = [Verse.placeholder]
        }
        return ordered
    }
}
