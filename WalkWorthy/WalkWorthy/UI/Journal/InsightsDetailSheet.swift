//
//  InsightsDetailSheet.swift
//  WalkWorthy
//
//  Detail sheet shown when tapping a node in the Insights graph.
//  Handles both tag hub nodes and check-in nodes.
//

import SwiftUI

struct InsightsDetailSheet: View {
    let hit: GraphSimulation.HitResult
    let allCheckInNodes: [InsightsNode]
    let edges: [InsightsEdge]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: scaled(16)) {
                    switch hit {
                    case .tagNode(let tag):
                        tagNodeContent(tag)
                    case .checkInNode(let node):
                        checkInNodeContent(node)
                    }
                }
                .padding(scaled(20))
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.newsreaderSemiBoldItalic(fixedSize: scaled(18)))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var title: String {
        switch hit {
        case .tagNode(let tag): return tag.label
        case .checkInNode: return "Check-in Details"
        }
    }

    // MARK: - Tag Node Content

    private func tagNodeContent(_ tag: InsightsTagNode) -> some View {
        let connectedIds = Set(
            edges.filter { $0.targetId == tag.id }.map(\.sourceId)
        )
        let connected = allCheckInNodes.filter { connectedIds.contains($0.id) }

        return VStack(alignment: .leading, spacing: scaled(16)) {
            // Header
            HStack(spacing: scaled(8)) {
                Circle()
                    .fill(tag.color)
                    .frame(width: scaled(14), height: scaled(14))
                Text(tag.isEmotionTag ? "Emotion Tag" : "Impact Category")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(connected.count) check-in\(connected.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Connected check-ins list
            ForEach(connected) { node in
                HStack(spacing: scaled(10)) {
                    Circle()
                        .fill(node.color)
                        .frame(width: scaled(10), height: scaled(10))
                    Text(Self.formatDate(node.date))
                        .font(.subheadline)
                    Spacer()
                    Text("\(node.moodScore)/10")
                        .font(.subheadline.bold())
                        .foregroundColor(node.color)
                    Text(node.checkInType.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, scaled(4))
            }
        }
    }

    // MARK: - Check-in Node Content

    private func checkInNodeContent(_ node: InsightsNode) -> some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            // Date header
            HStack(spacing: scaled(8)) {
                Image(systemName: node.checkInType.iconName)
                    .foregroundColor(node.checkInType.color)
                Text(Self.formatDate(node.date))
                    .font(.headline)
                Spacer()
                Text(node.checkInType.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Mood score
            HStack(spacing: scaled(12)) {
                Text("Mood")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(node.moodScore)/10")
                    .font(.title2.bold())
                    .foregroundColor(node.color)
                Circle()
                    .fill(node.color)
                    .frame(width: scaled(12), height: scaled(12))
            }
            .padding(scaled(12))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: scaled(12)))

            // Emotions
            if !node.emotionTags.isEmpty {
                VStack(alignment: .leading, spacing: scaled(8)) {
                    Text("Emotions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    FlowLayout(spacing: scaled(6)) {
                        ForEach(node.emotionTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, scaled(10))
                                .padding(.vertical, scaled(6))
                                .background(node.color.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // Impact categories
            if !node.impactCategories.isEmpty {
                VStack(alignment: .leading, spacing: scaled(8)) {
                    Text("Impact Areas")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    FlowLayout(spacing: scaled(6)) {
                        ForEach(node.impactCategories, id: \.self) { category in
                            Text(category)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, scaled(10))
                                .padding(.vertical, scaled(6))
                                .background(.primary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Date Formatting

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static func formatDate(_ dateString: String) -> String {
        guard let date = isoDateFormatter.date(from: dateString) else { return dateString }
        return displayDateFormatter.string(from: date)
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
