import AppKit

private final class WiFiPasswordFieldCell: NSSecureTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let textView = editor as? NSTextView {
            textView.contentType = NSTextContentType(rawValue: "")
            textView.isAutomaticTextCompletionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.inlinePredictionType = .no
            if #available(macOS 15.0, *) {
                textView.writingToolsBehavior = .none
                textView.mathExpressionCompletionType = .no
            }
        }
        return editor
    }
}

final class WiFiPasswordField: NSSecureTextField {
    override class var cellClass: AnyClass? {
        get { WiFiPasswordFieldCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInput()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInput()
    }

    override func becomeFirstResponder() -> Bool {
        configureInput()
        return super.becomeFirstResponder()
    }

    private func configureInput() {
        contentType = NSTextContentType(rawValue: "")
        isAutomaticTextCompletionEnabled = false
        (cell as? NSSecureTextFieldCell)?.echosBullets = true
    }
}
