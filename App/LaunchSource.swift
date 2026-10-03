import Foundation

/// What Kvotar does about the launch it just went through (REV-99 §2.4 — STEP_204). Pure, so
/// `KvotarTests` can pin it without AppKit, on the `OnboardingGate` pattern.
///
/// A deliberate cold launch — Finder, Spotlight, `open` — is the one thing a person does when
/// they cannot find the status item, so it opens the quota window. **Launch at login stays
/// silent**, exactly as it is today; a window appearing by itself at every sign-in would undermine
/// the one behaviour the rest of REV-99 rests on.
///
/// The three shapes below were observed on a real machine, including a logout and sign-in, in
/// `docs/spikes/SPIKE_E_status_item_visibility_2026-09-15.md` (raw logs in
/// `docs/evidence/SPIKE_E/`). The discriminator is the `'prdt'` parameter that `loginwindow`
/// attaches — `'lgit'`, "launched as a login item" — and nothing else: the two launches are
/// otherwise the same `aevt`/`oapp` event.
enum LaunchSource {
    enum Decision: Equatable {
        /// Deliberate: show the quota window.
        case showWindow
        /// Login, or nothing we recognise: open nothing.
        case stayQuiet
    }

    /// The launch Apple event reduced to the three things the rule reads. Four-character codes as
    /// strings, so a fixture reads like the probe log it was drawn from.
    struct Event: Equatable {
        let eventClass: String
        let eventID: String
        /// The `'prdt'` parameter's value where the event carries one; `nil` otherwise.
        let propertyData: String?

        init(eventClass: String, eventID: String, propertyData: String? = nil) {
            self.eventClass = eventClass
            self.eventID = eventID
            self.propertyData = propertyData
        }
    }

    static let openApplicationClass = "aevt"
    static let openApplicationID = "oapp"
    /// `loginwindow`'s "launched as a login item" property.
    static let loginItemProperty = "lgit"

    static func decide(event: Event?) -> Decision {
        // No launch event at all. Conservative on purpose: silence is the safe failure, and a
        // window nobody asked for is worse than a window nobody got.
        guard let event else { return .stayQuiet }
        // Anything that is not an open-application event is not a cold launch. A reopen (`rapp`)
        // has its own path — `applicationShouldHandleReopen` — and must not be answered twice.
        guard event.eventClass == openApplicationClass,
              event.eventID == openApplicationID else { return .stayQuiet }
        return event.propertyData == loginItemProperty ? .stayQuiet : .showWindow
    }

    /// A `FourCharCode` as the four characters it is. `AEEventClass`, `AEEventID` and the `'prdt'`
    /// descriptor all arrive in this form.
    static func code(_ value: FourCharCode) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
