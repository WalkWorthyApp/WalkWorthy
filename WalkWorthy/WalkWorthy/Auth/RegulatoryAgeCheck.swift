//
//  RegulatoryAgeCheck.swift
//  WalkWorthy
//
//  WalkWorthy is adults-only. Where a law makes app developers use the App
//  Store's age signal (Texas SB 2420 since June 4, 2026; Alabama, California,
//  Utah and Louisiana follow in 2027), the self-declared 18+ toggle is not
//  enough: Apple's age-assurance guidance says apps in those regions must check
//  the person's age with the Declared Age Range API, including 18+ apps.
//  Everywhere else the self-declaration stands.
//
//  The age range is read once, in memory, to decide eligibility. It is never
//  stored or sent anywhere — Texas §121.055 requires deleting app-store age
//  data once verification is complete.
//

import DeclaredAgeRange
import SwiftUI

enum RegulatoryAgeCheck {
    enum Outcome: Equatable {
        /// No regional requirement applies, or the App Store confirmed 18+.
        case adult
        /// The App Store reports an age range under 18.
        case underage
        /// The check is required here, but no age range could be obtained.
        case unconfirmed
    }

    static func run(_ requestAgeRange: DeclaredAgeRangeAction) async -> Outcome {
        guard await isRequiredInCurrentRegion() else { return .adult }
        let minimumAge = OnboardingForm.minimumAge
        do {
            switch try await requestAgeRange(ageGates: minimumAge) {
            case .sharing(let range):
                if let lower = range.lowerBound, lower >= minimumAge { return .adult }
                if let upper = range.upperBound, upper < minimumAge { return .underage }
                return .unconfirmed
            case .declinedSharing:
                return .unconfirmed
            @unknown default:
                return .unconfirmed
            }
        } catch {
            // Required but unavailable: fail closed so a regulated account
            // cannot sign up on the self-declaration alone.
            return .unconfirmed
        }
    }

    /// Whether this account's region legally requires the age signal. Before
    /// iOS 26.2 the system cannot say, so the self-declaration applies.
    private static func isRequiredInCurrentRegion() async -> Bool {
        do {
            if #available(iOS 26.4, *) {
                return try await AgeRangeService.shared.requiredRegulatoryFeatures
                    .contains(.declaredAgeRangeRequired)
            }
            if #available(iOS 26.2, *) {
                return try await AgeRangeService.shared.isEligibleForAgeFeatures
            }
        } catch {
            // Undeterminable (e.g. unsupported device): keep the
            // self-declaration rather than locking out every user.
        }
        return false
    }
}
