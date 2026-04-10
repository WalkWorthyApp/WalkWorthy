//
//  GraphSimulation.swift
//  WalkWorthy
//
//  Force-directed graph simulation using Verlet integration.
//  Supports two node types: tag hubs (larger) and check-in dots (smaller).
//

import Foundation
import SwiftUI

@Observable
final class GraphSimulation {
    // MARK: - State

    private(set) var checkInNodes: [InsightsNode] = []
    private(set) var tagNodes: [InsightsTagNode] = []
    private(set) var edges: [InsightsEdge] = []
    private(set) var isSettled = true
    private(set) var connectionCounts: [String: Int] = [:]

    // MARK: - Configuration

    private let repulsionStrength: CGFloat = -150
    private let tagRepulsionStrength: CGFloat = -400  // tags repel more to spread clusters
    private let springStrength: CGFloat = 0.008
    private let centerStrength: CGFloat = 0.005
    private let damping: CGFloat = 0.82
    private let freezeThreshold: CGFloat = 0.2
    private let maxRepulsionDistance: CGFloat = 500

    // Total node count across both types
    private var totalNodeCount: Int { checkInNodes.count + tagNodes.count }

    // MARK: - Setup

    func configure(
        checkInNodes: [InsightsNode],
        tagNodes: [InsightsTagNode],
        edges: [InsightsEdge],
        canvasSize: CGSize
    ) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let radius = min(canvasSize.width, canvasSize.height) * 0.35
        let total = checkInNodes.count + tagNodes.count

        // Place tag nodes first in an inner ring
        var placedTags = tagNodes
        for i in placedTags.indices {
            let angle = (CGFloat(i) / CGFloat(max(placedTags.count, 1))) * .pi * 2
            let r = radius * 0.5
            placedTags[i].position = CGPoint(
                x: center.x + cos(angle) * r,
                y: center.y + sin(angle) * r
            )
            placedTags[i].velocity = .zero
        }

        // Place check-in nodes in an outer ring
        var placedCheckIns = checkInNodes
        for i in placedCheckIns.indices {
            let angle = (CGFloat(i + tagNodes.count) / CGFloat(max(total, 1))) * .pi * 2
            placedCheckIns[i].position = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            placedCheckIns[i].velocity = .zero
        }

        self.checkInNodes = placedCheckIns
        self.tagNodes = placedTags
        self.edges = edges
        self.isSettled = false

        // Pre-compute connection counts
        var counts: [String: Int] = [:]
        for edge in edges {
            counts[edge.sourceId, default: 0] += 1
            counts[edge.targetId, default: 0] += 1
        }
        self.connectionCounts = counts
    }

    func clear() {
        checkInNodes = []
        tagNodes = []
        edges = []
        isSettled = true
    }

    // MARK: - Simulation Step

    func tick(canvasSize: CGSize) {
        guard !isSettled, totalNodeCount > 0 else { return }

        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let padding: CGFloat = 30

        applyRepulsion()
        applyAttraction()
        applyCentering(center: center)

        // Integrate check-in nodes
        var totalVelocity: CGFloat = 0
        for i in checkInNodes.indices {
            checkInNodes[i].velocity.x *= damping
            checkInNodes[i].velocity.y *= damping
            checkInNodes[i].position.x += checkInNodes[i].velocity.x
            checkInNodes[i].position.y += checkInNodes[i].velocity.y
            checkInNodes[i].position.x = max(padding, min(canvasSize.width - padding, checkInNodes[i].position.x))
            checkInNodes[i].position.y = max(padding, min(canvasSize.height - padding, checkInNodes[i].position.y))
            totalVelocity += abs(checkInNodes[i].velocity.x) + abs(checkInNodes[i].velocity.y)
        }

        // Integrate tag nodes (heavier damping — they move slower)
        for i in tagNodes.indices {
            tagNodes[i].velocity.x *= damping * 0.95
            tagNodes[i].velocity.y *= damping * 0.95
            tagNodes[i].position.x += tagNodes[i].velocity.x
            tagNodes[i].position.y += tagNodes[i].velocity.y
            tagNodes[i].position.x = max(padding, min(canvasSize.width - padding, tagNodes[i].position.x))
            tagNodes[i].position.y = max(padding, min(canvasSize.height - padding, tagNodes[i].position.y))
            totalVelocity += abs(tagNodes[i].velocity.x) + abs(tagNodes[i].velocity.y)
        }

        if totalVelocity / CGFloat(max(totalNodeCount, 1)) < freezeThreshold {
            isSettled = true
        }
    }

    // MARK: - Forces

    private func applyRepulsion() {
        // Check-in ↔ check-in repulsion
        for i in 0..<checkInNodes.count {
            for j in (i + 1)..<checkInNodes.count {
                applyRepulsionBetween(
                    posA: checkInNodes[i].position, posB: checkInNodes[j].position,
                    strength: repulsionStrength
                ) { fx, fy in
                    checkInNodes[i].velocity.x -= fx
                    checkInNodes[i].velocity.y -= fy
                    checkInNodes[j].velocity.x += fx
                    checkInNodes[j].velocity.y += fy
                }
            }
        }

        // Tag ↔ tag repulsion (stronger)
        for i in 0..<tagNodes.count {
            for j in (i + 1)..<tagNodes.count {
                applyRepulsionBetween(
                    posA: tagNodes[i].position, posB: tagNodes[j].position,
                    strength: tagRepulsionStrength
                ) { fx, fy in
                    tagNodes[i].velocity.x -= fx
                    tagNodes[i].velocity.y -= fy
                    tagNodes[j].velocity.x += fx
                    tagNodes[j].velocity.y += fy
                }
            }
        }

        // Check-in ↔ tag repulsion
        for i in 0..<checkInNodes.count {
            for j in 0..<tagNodes.count {
                applyRepulsionBetween(
                    posA: checkInNodes[i].position, posB: tagNodes[j].position,
                    strength: repulsionStrength
                ) { fx, fy in
                    checkInNodes[i].velocity.x -= fx
                    checkInNodes[i].velocity.y -= fy
                    tagNodes[j].velocity.x += fx
                    tagNodes[j].velocity.y += fy
                }
            }
        }
    }

    private func applyRepulsionBetween(
        posA: CGPoint, posB: CGPoint,
        strength: CGFloat,
        apply: (CGFloat, CGFloat) -> Void
    ) {
        let dx = posA.x - posB.x
        let dy = posA.y - posB.y
        let distSq = max(dx * dx + dy * dy, 1)
        let dist = sqrt(distSq)
        guard dist < maxRepulsionDistance else { return }

        let force = strength / distSq
        let fx = (dx / dist) * force
        let fy = (dy / dist) * force
        apply(fx, fy)
    }

    private func applyAttraction() {
        // Build index for both node types
        var checkInIndex: [String: Int] = [:]
        for (i, node) in checkInNodes.enumerated() { checkInIndex[node.id] = i }
        var tagIndex: [String: Int] = [:]
        for (i, node) in tagNodes.enumerated() { tagIndex[node.id] = i }

        for edge in edges {
            // Edges go: sourceId = check-in, targetId = tag
            guard let ci = checkInIndex[edge.sourceId],
                  let ti = tagIndex[edge.targetId] else { continue }

            let dx = tagNodes[ti].position.x - checkInNodes[ci].position.x
            let dy = tagNodes[ti].position.y - checkInNodes[ci].position.y

            let fx = dx * springStrength
            let fy = dy * springStrength

            checkInNodes[ci].velocity.x += fx
            checkInNodes[ci].velocity.y += fy
            tagNodes[ti].velocity.x -= fx * 0.3  // tags move less (heavier)
            tagNodes[ti].velocity.y -= fy * 0.3
        }
    }

    private func applyCentering(center: CGPoint) {
        for i in checkInNodes.indices {
            let dx = center.x - checkInNodes[i].position.x
            let dy = center.y - checkInNodes[i].position.y
            checkInNodes[i].velocity.x += dx * centerStrength
            checkInNodes[i].velocity.y += dy * centerStrength
        }
        for i in tagNodes.indices {
            let dx = center.x - tagNodes[i].position.x
            let dy = center.y - tagNodes[i].position.y
            tagNodes[i].velocity.x += dx * centerStrength
            tagNodes[i].velocity.y += dy * centerStrength
        }
    }

    // MARK: - Interaction

    /// Hit-test: check tag nodes first (larger), then check-in nodes.
    /// Returns either a tag node ID or check-in node ID.
    enum HitResult {
        case tagNode(InsightsTagNode)
        case checkInNode(InsightsNode)
    }

    func nodeAt(_ point: CGPoint, radius: CGFloat = 30) -> HitResult? {
        var closestDist = CGFloat.greatestFiniteMagnitude
        var result: HitResult?

        // Tag nodes get larger hit area
        for node in tagNodes {
            let dx = node.position.x - point.x
            let dy = node.position.y - point.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < radius * 1.5 && dist < closestDist {
                result = .tagNode(node)
                closestDist = dist
            }
        }

        for node in checkInNodes {
            let dx = node.position.x - point.x
            let dy = node.position.y - point.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < radius && dist < closestDist {
                result = .checkInNode(node)
                closestDist = dist
            }
        }

        return result
    }

    func pinNode(id: String, to position: CGPoint) {
        if let idx = checkInNodes.firstIndex(where: { $0.id == id }) {
            checkInNodes[idx].position = position
            checkInNodes[idx].velocity = .zero
        } else if let idx = tagNodes.firstIndex(where: { $0.id == id }) {
            tagNodes[idx].position = position
            tagNodes[idx].velocity = .zero
        }
        isSettled = false
    }

    func wake() {
        isSettled = false
    }
}
