//
//  IntelligenceAvailability.swift
//  MarkDevKit
//
//  Whether the on-device model can run, and what to say when it cannot.
//

import FoundationModels
import Foundation

/// Why MarkDev's writing tools are, or are not, usable right now.
///
/// # Why this is not a Bool
///
/// Each way Apple Intelligence can be missing needs its own sentence.
/// A Mac that will never run the model, one whose owner has not
/// switched the feature on, and one that is still downloading weights are
/// three entirely different situations, and only one of them is worth waiting
/// for. Collapsing them into `isAvailable` is exactly what produces the "the
/// AI features don't work and there is nothing on screen to tell me why"
/// experience — so the reason is carried all the way to the panel.
public enum IntelligenceState: Equatable, Sendable, CaseIterable {
    /// The model is loaded and the current language is supported.
    case ready
    /// This Mac cannot run Apple Intelligence at all.
    case deviceNotEligible
    /// Eligible, but Apple Intelligence has not been turned on.
    case notEnabled
    /// Turned on, but the assets are still downloading or preparing.
    case modelNotReady
    /// The model does not handle the language this Mac is set to.
    case languageUnsupported
    /// Unavailable for a reason this build does not recognise.
    ///
    /// `UnavailableReason` is not frozen, so a later macOS can add one. It is
    /// mapped to its own case rather than folded into the nearest neighbour:
    /// telling someone their model is "still downloading" when it is not is
    /// worse than admitting the app does not know.
    case unavailableForUnknownReason

    public var isReady: Bool { self == .ready }

    /// One short line, suitable for a panel header.
    public var headline: String {
        switch self {
        case .ready: "Apple Intelligence"
        case .deviceNotEligible: "Not available on this Mac"
        case .notEnabled: "Apple Intelligence is off"
        case .modelNotReady: "Preparing Apple Intelligence"
        case .languageUnsupported: "Language not supported"
        case .unavailableForUnknownReason: "Apple Intelligence unavailable"
        }
    }

    /// What the reader can actually do about it. Empty when nothing is wrong.
    public var guidance: String {
        switch self {
        case .ready:
            ""
        case .deviceNotEligible:
            "This Mac doesn’t support Apple Intelligence, so the writing tools can’t run on it."
        case .notEnabled:
            "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri to use the writing tools."
        case .modelNotReady:
            "The on-device model is still downloading. The writing tools will work once it finishes."
        case .languageUnsupported:
            "Apple Intelligence doesn’t support this Mac’s language yet, so the writing tools are unavailable."
        case .unavailableForUnknownReason:
            "Apple Intelligence reported that it is unavailable, for a reason this version of MarkDev doesn’t recognise."
        }
    }

    public var symbol: String {
        switch self {
        case .ready: "apple.intelligence"
        case .deviceNotEligible: "exclamationmark.triangle"
        case .notEnabled: "switch.2"
        case .modelNotReady: "arrow.down.circle"
        case .languageUnsupported: "globe"
        case .unavailableForUnknownReason: "questionmark.circle"
        }
    }
}

/// Reads the system model's availability.
public enum IntelligenceAvailability {
    /// Maps a framework availability plus a locale check onto ``IntelligenceState``.
    ///
    /// Split out from ``current(model:locale:)`` because it is the whole of the
    /// decision and the only part that can be exercised in a test: an
    /// unavailable `SystemLanguageModel` cannot be constructed on a Mac where
    /// the model is present, so the mapping would otherwise only ever be run
    /// down its happy path.
    ///
    /// Availability is checked *before* the locale. A Mac that cannot run the
    /// model at all should not be told its language is the problem.
    public static func state(
        of availability: SystemLanguageModel.Availability,
        supportsLocale: Bool
    ) -> IntelligenceState {
        switch availability {
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .available:
            return supportsLocale ? .ready : .languageUnsupported
        case .unavailable:
            return .unavailableForUnknownReason
        }
    }

    /// The state of the default system model for `locale`.
    public static func current(
        model: SystemLanguageModel = .default,
        locale: Locale = .current
    ) -> IntelligenceState {
        state(of: model.availability, supportsLocale: model.supportsLocale(locale))
    }
}
