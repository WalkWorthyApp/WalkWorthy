//
//  InsightsModels.swift
//  WalkWorthy
//
//  Models for the journal insights network graph feature.
//

import Foundation
import SwiftUI

// MARK: - API Response

struct InsightsResponse: Codable {
    let checkIns: [InsightsCheckIn]
}

struct InsightsCheckIn: Codable, Identifiable {
    let id: String
    let checkInType: String
    let date: String
    let timestamp: String
    let moodScore: Int
    let moodLevel: String
    let emotionTags: [String]
    let impactCategories: [String]

    var checkInTypeEnum: CheckInType? {
        CheckInType(rawValue: checkInType)
    }

    var moodLevelEnum: MoodLevel? {
        MoodLevel(rawValue: moodLevel)
    }
}

// MARK: - Graph Node Types

/// A check-in node (small dot) in the insights graph.
struct InsightsNode: Identifiable {
    let id: String
    let date: String
    let moodScore: Int
    let emotionTags: [String]
    let impactCategories: [String]
    let checkInType: CheckInType
    var position: CGPoint = .zero
    var velocity: CGPoint = .zero

    /// Color based on mood score
    var color: Color {
        let level = MoodLevel.from(score: moodScore)
        return level.sentiment.color
    }

    init(from checkIn: InsightsCheckIn) {
        self.id = checkIn.id
        self.date = checkIn.date
        self.moodScore = checkIn.moodScore
        self.emotionTags = checkIn.emotionTags
        self.impactCategories = checkIn.impactCategories
        self.checkInType = checkIn.checkInTypeEnum ?? .morning
    }
}

/// A tag hub node (larger, labeled) in the insights graph.
struct InsightsTagNode: Identifiable {
    let id: String
    let label: String
    let isEmotionTag: Bool
    var position: CGPoint = .zero
    var velocity: CGPoint = .zero

    /// Emotion tags = green, impact categories = blue-gray
    var color: Color {
        isEmotionTag
            ? Color(red: 0.3, green: 0.75, blue: 0.45)
            : Color(red: 0.55, green: 0.65, blue: 0.8)
    }
}

/// An edge connecting a check-in node to a tag hub node.
struct InsightsEdge: Identifiable {
    let id: String
    let sourceId: String  // check-in node ID
    let targetId: String  // tag node ID
}

// MARK: - Graph Building

struct InsightsGraphResult {
    let tagNodes: [InsightsTagNode]
    let edges: [InsightsEdge]
}

enum InsightsGraphBuilder {
    /// Build the full graph: tag hub nodes + edges from check-ins to their tags.
    static func buildGraph(from checkInNodes: [InsightsNode]) -> InsightsGraphResult {
        // Collect all used emotion tags and impact categories
        var emotionTags = Set<String>()
        var impactCategories = Set<String>()
        for node in checkInNodes {
            emotionTags.formUnion(node.emotionTags)
            impactCategories.formUnion(node.impactCategories)
        }

        // Create tag hub nodes
        var tagNodes: [InsightsTagNode] = []
        for tag in emotionTags {
            tagNodes.append(InsightsTagNode(
                id: "tag_emotion_\(tag)",
                label: tag,
                isEmotionTag: true
            ))
        }
        for category in impactCategories {
            tagNodes.append(InsightsTagNode(
                id: "tag_impact_\(category)",
                label: category,
                isEmotionTag: false
            ))
        }

        // Create edges: each check-in connects to each of its tags
        var edges: [InsightsEdge] = []
        for node in checkInNodes {
            for tag in node.emotionTags {
                edges.append(InsightsEdge(
                    id: "\(node.id)_tag_emotion_\(tag)",
                    sourceId: node.id,
                    targetId: "tag_emotion_\(tag)"
                ))
            }
            for category in node.impactCategories {
                edges.append(InsightsEdge(
                    id: "\(node.id)_tag_impact_\(category)",
                    sourceId: node.id,
                    targetId: "tag_impact_\(category)"
                ))
            }
        }

        return InsightsGraphResult(tagNodes: tagNodes, edges: edges)
    }
}
