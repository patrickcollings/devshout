import Foundation

/// What is known about the focused UI element, read through Accessibility on macOS.
public struct FocusedElementInfo: Sendable, Hashable {
    /// The element's AXRole (e.g. "AXTextArea"), when it could be read.
    public var role: String?
    /// The element's AXSubrole (e.g. "AXSecureTextField" for a password field), when it could be read.
    public var subrole: String?
    /// Whether AXValue is settable, when it could be read.
    public var valueSettable: Bool?
    /// Whether AXSelectedText is settable, when it could be read.
    public var selectedTextSettable: Bool?

    public init(role: String? = nil, subrole: String? = nil, valueSettable: Bool? = nil,
                selectedTextSettable: Bool? = nil) {
        self.role = role
        self.subrole = subrole
        self.valueSettable = valueSettable
        self.selectedTextSettable = selectedTextSettable
    }

    /// True for a password field, false for any other element whose role was read, nil when unknown.
    public var isPasswordField: Bool? {
        if subrole == "AXSecureTextField" { return true }
        return role == nil ? nil : false
    }
}

/// Whether the focused element takes text.
public enum FocusEditability: Sendable, Hashable {
    case editable
    case notEditable
    /// Accessibility couldn't say (no focused element reported, an error, a web view or a custom view).
    /// devshout pastes anyway: many apps (Electron, terminals, games) report little or nothing.
    case unknown

    /// Roles that never take typed text. Only these, with nothing settable, count as "not editable". Generic
    /// containers (AXGroup, AXScrollArea, AXWebArea, AXUnknown) are left as unknown, because terminals and web
    /// apps often report focus that way.
    public static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
        "AXSlider", "AXIncrementor", "AXImage", "AXStaticText", "AXLink", "AXMenu", "AXMenuBar", "AXMenuItem",
        "AXMenuBarItem", "AXList", "AXTable", "AXOutline", "AXBrowser", "AXRow", "AXCell", "AXColumn",
        "AXTabGroup", "AXToolbar", "AXDockItem", "AXProgressIndicator", "AXBusyIndicator", "AXColorWell",
        "AXValueIndicator", "AXRuler", "AXSplitter",
    ]

    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Best-effort classification. `nil` info means there was no focused element or it couldn't be read.
    public static func classify(_ info: FocusedElementInfo?) -> FocusEditability {
        guard let info else { return .unknown }
        if info.valueSettable == true || info.selectedTextSettable == true { return .editable }
        guard let role = info.role else { return .unknown }
        if textRoles.contains(role) { return .editable }
        if nonTextRoles.contains(role),
           info.valueSettable == false || info.valueSettable == nil,
           info.selectedTextSettable == false || info.selectedTextSettable == nil {
            return .notEditable
        }
        return .unknown
    }
}

/// Why ⌘V was not sent. The text is on the clipboard in every case.
public enum PasteSkipReason: String, Sendable, Hashable, CaseIterable {
    case accessibilityNotTrusted
    case secureInput
    case passwordField
    case devshoutFrontmost
    case noEditableFocus

    /// Short British-English text for the overlay and history ("Copied: press ⌘V" is shown alongside).
    public var message: String {
        switch self {
        case .accessibilityNotTrusted: "devshout needs Accessibility permission to paste for you"
        case .secureInput: "Secure input is on, so a password field may have focus"
        case .passwordField: "A password field has focus"
        case .devshoutFrontmost: "devshout's own window is in front"
        case .noEditableFocus: "No text field has focus"
        }
    }
}

/// Decides, before pasting, whether to send ⌘V or only leave the text on the clipboard (PLAN §3.3 step 3).
public enum PastePreflight {
    public struct Conditions: Sendable, Hashable {
        public var accessibilityTrusted: Bool
        public var secureInputEnabled: Bool
        public var devshoutFrontmost: Bool
        public var focus: FocusEditability
        /// `FocusedElementInfo.isPasswordField`: nil when unknown.
        public var focusIsPasswordField: Bool?

        public init(accessibilityTrusted: Bool, secureInputEnabled: Bool, devshoutFrontmost: Bool,
                    focus: FocusEditability, focusIsPasswordField: Bool? = nil) {
            self.accessibilityTrusted = accessibilityTrusted
            self.secureInputEnabled = secureInputEnabled
            self.devshoutFrontmost = devshoutFrontmost
            self.focus = focus
            self.focusIsPasswordField = focusIsPasswordField
        }

        public init(accessibilityTrusted: Bool, secureInputEnabled: Bool, devshoutFrontmost: Bool,
                    focused info: FocusedElementInfo?) {
            self.init(accessibilityTrusted: accessibilityTrusted, secureInputEnabled: secureInputEnabled,
                      devshoutFrontmost: devshoutFrontmost, focus: FocusEditability.classify(info),
                      focusIsPasswordField: info?.isPasswordField)
        }
    }

    /// The text as it goes on the clipboard: trailing newlines are dropped, so pasting never submits anything in a
    /// terminal or chat box (PLAN §3.3 step 4). Leading and inner whitespace are kept.
    public static func textToDeliver(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isNewline { text.removeLast() }
        return text
    }

    /// `nil` means go ahead and paste. Checks run in order of how certain they are.
    ///
    /// Secure Event Input is system-wide: any app can hold it (Terminal's Secure Keyboard Entry, a password
    /// manager), not just a password field in the target app. So when it is on, devshout still pastes if the
    /// focused element is known not to be a password field, and skips only when it is one or can't be read.
    public static func skipReason(_ c: Conditions) -> PasteSkipReason? {
        if !c.accessibilityTrusted { return .accessibilityNotTrusted }
        if c.devshoutFrontmost { return .devshoutFrontmost }
        if c.focusIsPasswordField == true { return .passwordField }
        if c.secureInputEnabled, c.focusIsPasswordField == nil { return .secureInput }
        if c.focus == .notEditable { return .noEditableFocus }
        return nil
    }
}
