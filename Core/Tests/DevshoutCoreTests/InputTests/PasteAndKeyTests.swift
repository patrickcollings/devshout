import Foundation
import Testing
@testable import DevshoutCore

@Suite struct FocusEditabilityTests {
    @Test func textRolesAreEditable() {
        #expect(FocusEditability.classify(.init(role: "AXTextArea")) == .editable)
        #expect(FocusEditability.classify(.init(role: "AXTextField", valueSettable: false)) == .editable)
    }

    @Test func settableAttributesAreEditable() {
        #expect(FocusEditability.classify(.init(role: "AXGroup", valueSettable: true)) == .editable)
        #expect(FocusEditability.classify(.init(role: "AXWebArea", selectedTextSettable: true)) == .editable)
        // Even a "non-text" role counts when it says text can be set.
        #expect(FocusEditability.classify(.init(role: "AXList", selectedTextSettable: true)) == .editable)
    }

    @Test func nonTextRolesWithNothingSettable() {
        #expect(FocusEditability.classify(.init(role: "AXButton", valueSettable: false, selectedTextSettable: false))
            == .notEditable)
        #expect(FocusEditability.classify(.init(role: "AXTable")) == .notEditable)
    }

    @Test func unsureMeansUnknown() {
        #expect(FocusEditability.classify(nil) == .unknown)
        #expect(FocusEditability.classify(.init()) == .unknown)
        #expect(FocusEditability.classify(.init(role: "AXGroup", valueSettable: false)) == .unknown)
        #expect(FocusEditability.classify(.init(role: "AXWebArea")) == .unknown)
        #expect(FocusEditability.classify(.init(role: "AXUnknown")) == .unknown)
    }
}

@Suite struct PastePreflightTests {
    private func conditions(trusted: Bool = true, secure: Bool = false, own: Bool = false,
                            focus: FocusEditability = .editable,
                            password: Bool? = false) -> PastePreflight.Conditions {
        .init(accessibilityTrusted: trusted, secureInputEnabled: secure, devshoutFrontmost: own, focus: focus,
              focusIsPasswordField: password)
    }

    @Test func pastesWhenAllClear() {
        #expect(PastePreflight.skipReason(conditions()) == nil)
        #expect(PastePreflight.skipReason(conditions(focus: .unknown, password: nil)) == nil) // unsure: paste anyway
    }

    @Test func skipReasons() {
        #expect(PastePreflight.skipReason(conditions(trusted: false)) == .accessibilityNotTrusted)
        #expect(PastePreflight.skipReason(conditions(own: true)) == .devshoutFrontmost)
        #expect(PastePreflight.skipReason(conditions(password: true)) == .passwordField)
        #expect(PastePreflight.skipReason(conditions(focus: .notEditable)) == .noEditableFocus)
    }

    @Test func secureInputSkipsOnlyWhenFocusIsUnknownOrPassword() {
        // Another app holds secure input (e.g. Terminal's Secure Keyboard Entry); the focused field is ordinary.
        #expect(PastePreflight.skipReason(conditions(secure: true, password: false)) == nil)
        #expect(PastePreflight.skipReason(conditions(secure: true, focus: .unknown, password: nil)) == .secureInput)
        #expect(PastePreflight.skipReason(conditions(secure: true, password: true)) == .passwordField)
    }

    @Test func orderOfChecks() {
        #expect(PastePreflight.skipReason(conditions(trusted: false, secure: true, own: true, focus: .notEditable,
                                                     password: nil)) == .accessibilityNotTrusted)
        #expect(PastePreflight.skipReason(conditions(secure: true, own: true, password: nil)) == .devshoutFrontmost)
        #expect(PastePreflight.skipReason(conditions(secure: true, focus: .notEditable, password: nil)) == .secureInput)
    }

    @Test func conditionsFromFocusedInfo() {
        let password = FocusedElementInfo(role: "AXTextField", subrole: "AXSecureTextField", valueSettable: true)
        let c = PastePreflight.Conditions(accessibilityTrusted: true, secureInputEnabled: true,
                                          devshoutFrontmost: false, focused: password)
        #expect(c.focus == .editable)
        #expect(c.focusIsPasswordField == true)
        #expect(PastePreflight.skipReason(c) == .passwordField)

        let none = PastePreflight.Conditions(accessibilityTrusted: true, secureInputEnabled: false,
                                             devshoutFrontmost: false, focused: nil)
        #expect(none.focus == .unknown)
        #expect(none.focusIsPasswordField == nil)
        #expect(PastePreflight.skipReason(none) == nil)
    }

    @Test func passwordFieldDetection() {
        #expect(FocusedElementInfo(role: "AXTextField", subrole: "AXSecureTextField").isPasswordField == true)
        #expect(FocusedElementInfo(role: "AXTextArea").isPasswordField == false)
        #expect(FocusedElementInfo().isPasswordField == nil)
    }

    @Test func messagesAreSet() {
        for reason in PasteSkipReason.allCases { #expect(!reason.message.isEmpty) }
    }
}

@Suite struct KeyCodeSearchTests {
    private static let qwerty: [UInt16: String] = [0: "a", 1: "s", 8: "c", 9: "v", 11: "b"]
    // Dvorak: the key at kVK_ANSI_Period (47) types "v"; kVK_ANSI_V (9) types "k".
    private static let dvorak: [UInt16: String] = [0: "a", 9: "k", 47: "v", 8: "j"]

    @Test func qwertyFindsAnsiV() {
        #expect(KeyCodeSearch.keyCode(producing: "v") { Self.qwerty[$0] } == 9)
    }

    @Test func dvorakFindsMovedKey() {
        #expect(KeyCodeSearch.keyCode(producing: "v") { Self.dvorak[$0] } == 47)
    }

    @Test func caseInsensitive() {
        #expect(KeyCodeSearch.keyCode(producing: "v") { $0 == 20 ? "V" : nil } == 20)
    }

    @Test func prefersPreferredWhenSeveralMatch() {
        #expect(KeyCodeSearch.keyCode(producing: "v") { $0 == 3 || $0 == 9 ? "v" : nil } == 9)
        #expect(KeyCodeSearch.keyCode(producing: "v", preferred: nil) { $0 == 3 || $0 == 9 ? "v" : nil } == 3)
    }

    @Test func nonLatinLayoutGivesNil() {
        #expect(KeyCodeSearch.keyCode(producing: "v") { _ in "м" } == nil)
        #expect(KeyCodeSearch.keyCode(producing: "v") { _ in nil } == nil)
    }
}

@Suite struct PollerTests {
    private actor Counter {
        var n = 0
        func next() -> Int { n += 1; return n }
    }

    @Test func returnsOnceConditionHolds() async {
        let counter = Counter()
        let ok = await Poller.waitUntil(interval: .milliseconds(5)) { await counter.next() >= 3 }
        #expect(ok)
        #expect(await counter.n == 3)
    }

    @Test func timesOut() async {
        let ok = await Poller.waitUntil(interval: .milliseconds(5), timeout: .milliseconds(30)) { false }
        #expect(!ok)
    }

    @Test func stopsWhenCancelled() async {
        let task = Task { await Poller.waitUntil(interval: .milliseconds(5)) { false } }
        task.cancel()
        #expect(await task.value == false)
    }
}

@Suite struct TextToDeliverTests {
    @Test func dropsTrailingNewlinesOnly() {
        #expect(PastePreflight.textToDeliver("Hello\n") == "Hello")
        #expect(PastePreflight.textToDeliver("Hello\r\n\n") == "Hello")
        #expect(PastePreflight.textToDeliver("- one\n- two\n") == "- one\n- two")
        #expect(PastePreflight.textToDeliver("  indented") == "  indented")
        #expect(PastePreflight.textToDeliver("\n") == "")
        #expect(PastePreflight.textToDeliver("No newline") == "No newline")
    }
}
