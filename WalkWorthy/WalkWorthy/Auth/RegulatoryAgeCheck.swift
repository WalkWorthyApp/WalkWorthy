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
//  Runs at sign-in (SignInFormView) and once per launch for a restored session
//  (RootView). The age range is read once, in memory, to decide eligibility.
//  It is never stored or sent anywhere — Texas §121.055 requires deleting
//  app-store age data once verification is complete.
//

import DeclaredAgeRange
import SwiftUI

enum RegulatoryAgeCheck {
    enum Outcome: Equatable {
        /// No regional requirement applies, or the App Store confirmed 18+.
        case adult
        /// The App Store reports an age range under 18.
        case underage
        /// The check applies, but no age range could be obtained.
        case unconfirmed

        /// What to tell the person when they can't continue.
        var message: String? {
            switch self {
            case .adult:
                return nil
            case .underage:
                return "Your App Store account shows an age under 18. WalkWorthy is only available to adults."
            case .unconfirmed:
                return "WalkWorthy needs to confirm with the App Store that you're 18 or older. Share your age range to continue."
            }
        }
    }

    /// Set once a check passes, so a sign-in followed by the restored-session
    /// check doesn't ask the same person twice in one launch.
    private(set) static var confirmedThisLaunch = false

    static func run(_ requestAgeRange: DeclaredAgeRangeAction) async -> Outcome {
        let outcome: Outcome
        switch await regionRequirement() {
        case .notRequired:
            outcome = .adult
        case .required:
            // Fail closed: a regulated account can't proceed on the
            // self-declaration alone.
            outcome = await requestRange(requestAgeRange, ifServiceUnavailable: .unconfirmed)
        case .unknown:
            // We couldn't tell whether the law applies here, so ask anyway
            // rather than skip the check. Only if the age service itself is
            // unavailable does the self-declaration stand.
            outcome = await requestRange(requestAgeRange, ifServiceUnavailable: .adult)
        }
        if outcome == .adult { confirmedThisLaunch = true }
        return outcome
    }

    private enum Requirement { case required, notRequired, unknown }

    private static func regionRequirement() async -> Requirement {
        do {
            if #available(iOS 26.4, *) {
                return try await AgeRangeService.shared.requiredRegulatoryFeatures
                    .contains(.declaredAgeRangeRequired) ? .required : .notRequired
            }
            return try await AgeRangeService.shared.isEligibleForAgeFeatures ? .required : .notRequired
        } catch {
            return .unknown
        }
    }

    private static func requestRange(
        _ requestAgeRange: DeclaredAgeRangeAction,
        ifServiceUnavailable fallback: Outcome
    ) async -> Outcome {
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
            return fallback
        }
    }
}
