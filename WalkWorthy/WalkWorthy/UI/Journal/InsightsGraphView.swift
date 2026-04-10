//
//  InsightsGraphView.swift
//  WalkWorthy
//
//  Obsidian-style force-directed network graph showing all mood check-ins
//  and their tag/category connections. Tags are hub nodes with labels,
//  check-ins are small colored dots.
//

import SwiftUI

struct InsightsGraphView: View {
    @EnvironmentObject private var appState: AppState
    @State private var simulation = GraphSimulation()
    @State private var selectedHit: GraphSimulation.HitResult?
    @State private var showingDetail = false
    @State private var draggedNodeId: String?
    @State private var scale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var hasConfigured = false

    var body: some View {
        graphCanvas
            .task {
                await appState.loadInsightsData()
            }
            .sheet(isPresented: $showingDetail) {
                if let hit = selectedHit {
                    InsightsDetailSheet(
                        hit: hit,
                        allCheckInNodes: simulation.checkInNodes,
                        edges: simulation.edges
                    )
                }
            }
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            ZStack {
                if appState.insightsLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.insightsNodes.isEmpty {
                    emptyState
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: simulation.isSettled)) { timeline in
                        Canvas { context, size in
                            drawEdges(context: &context)
                            drawCheckInNodes(context: &context)
                            drawTagNodes(context: &context)
                        }
                        .onChange(of: timeline.date) { _, _ in
                            let wasSettled = simulation.isSettled
                            simulation.tick(canvasSize: canvasSize)
                            if !wasSettled && simulation.isSettled {
                                fitGraphToCanvas()
                            }
                        }
                        .gesture(tapGesture)
                        .gesture(dragGesture)
                        .gesture(magnifyGesture)
                    }
                }
            }
            .onAppear {
                canvasSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
            }
            .onChange(of: appState.insightsNodes.count) { _, _ in
                configureGraph()
            }
        }
    }

    // MARK: - Drawing

    private func drawEdges(context: inout GraphicsContext) {
        for edge in simulation.edges {
            let sourcePos = findPosition(id: edge.sourceId)
            let targetPos = findPosition(id: edge.targetId)
            guard let source = sourcePos, let target = targetPos else { continue }

            var path = Path()
            path.move(to: transformPoint(source))
            path.addLine(to: transformPoint(target))

            context.stroke(
                path,
                with: .color(.primary.opacity(0.35)),
                lineWidth: 1
            )
        }
    }

    private func drawCheckInNodes(context: inout GraphicsContext) {
        for node in simulation.checkInNodes {
            let point = transformPoint(node.position)
            let radius = scaled(5)

            let nodeRect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Circle().path(in: nodeRect),
                with: .color(node.color.opacity(0.85))
            )
        }
    }

    private func drawTagNodes(context: inout GraphicsContext) {
        for node in simulation.tagNodes {
            let point = transformPoint(node.position)
            let connections = simulation.connectionCounts[node.id] ?? 0
            let baseRadius = scaled(16)
            let radius = baseRadius + CGFloat(min(connections, 15)) * scaled(3)

            // Glow
            let glowRect = CGRect(
                x: point.x - radius * 1.8,
                y: point.y - radius * 1.8,
                width: radius * 3.6,
                height: radius * 3.6
            )
            context.fill(
                Circle().path(in: glowRect),
                with: .color(node.color.opacity(0.15))
            )

            // Node circle
            let nodeRect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Circle().path(in: nodeRect),
                with: .color(node.color.opacity(0.6))
            )
            context.stroke(
                Circle().path(in: nodeRect),
                with: .color(node.color.opacity(0.8)),
                lineWidth: 1
            )

            // Label text — scales with node size
            let fontSize = scaled(9) + CGFloat(min(connections, 10)) * scaled(0.5)
            let text = Text(node.label)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(.primary)
            context.draw(
                context.resolve(text),
                at: CGPoint(x: point.x, y: point.y + radius + scaled(8)),
                anchor: .top
            )
        }
    }

    // MARK: - Helpers

    private func findPosition(id: String) -> CGPoint? {
        if let node = simulation.checkInNodes.first(where: { $0.id == id }) {
            return node.position
        }
        if let node = simulation.tagNodes.first(where: { $0.id == id }) {
            return node.position
        }
        return nil
    }

    private func transformPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * scale + offset.width,
            y: point.y * scale + offset.height
        )
    }

    private func inverseTransformPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - offset.width) / scale,
            y: (point.y - offset.height) / scale
        )
    }

    // MARK: - Gestures

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let simPoint = inverseTransformPoint(value.location)
                if let hit = simulation.nodeAt(simPoint) {
                    selectedHit = hit
                    showingDetail = true
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let simPoint = inverseTransformPoint(value.location)
                if draggedNodeId == nil {
                    if let hit = simulation.nodeAt(simPoint) {
                        switch hit {
                        case .tagNode(let node): draggedNodeId = node.id
                        case .checkInNode(let node): draggedNodeId = node.id
                        }
                    }
                }
                if let id = draggedNodeId {
                    simulation.pinNode(id: id, to: simPoint)
                } else {
                    offset = CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                if draggedNodeId != nil {
                    simulation.wake()
                    draggedNodeId = nil
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(0.3, min(3.0, baseScale * value.magnification))
            }
            .onEnded { value in
                baseScale = max(0.3, min(3.0, baseScale * value.magnification))
            }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: scaled(16)) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: scaled(48)))
                .foregroundColor(.secondary)

            Text("Check in a few times to start seeing your patterns here.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, scaled(40))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Auto-fit

    private func fitGraphToCanvas() {
        // Collect all node positions
        let allPositions = simulation.checkInNodes.map(\.position) + simulation.tagNodes.map(\.position)
        guard !allPositions.isEmpty else { return }

        let minX = allPositions.map(\.x).min()!
        let maxX = allPositions.map(\.x).max()!
        let minY = allPositions.map(\.y).min()!
        let maxY = allPositions.map(\.y).max()!

        let graphWidth = maxX - minX
        let graphHeight = maxY - minY
        guard graphWidth > 0, graphHeight > 0 else { return }

        let padding: CGFloat = scaled(60)
        let availableWidth = canvasSize.width - padding * 2
        let availableHeight = canvasSize.height - padding * 2

        let fitScale = min(availableWidth / graphWidth, availableHeight / graphHeight, 1.5)

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        withAnimation(.easeInOut(duration: 0.4)) {
            scale = fitScale
            baseScale = fitScale
            offset = CGSize(
                width: canvasSize.width / 2 - centerX * fitScale,
                height: canvasSize.height / 2 - centerY * fitScale
            )
        }
    }

    // MARK: - Configuration

    private func configureGraph() {
        guard !appState.insightsNodes.isEmpty, canvasSize != .zero else { return }

        let graph = InsightsGraphBuilder.buildGraph(from: appState.insightsNodes)
        simulation.configure(
            checkInNodes: appState.insightsNodes,
            tagNodes: graph.tagNodes,
            edges: graph.edges,
            canvasSize: canvasSize
        )
        hasConfigured = true
    }
}
