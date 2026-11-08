import AppKit

// MARK: - 极小的富文本标记

/// 产品文案里需要强调某几个字（"**没法取消 Enter=重命名**"），
/// 但把 NSAttributedString 拼装逻辑散到 UI 代码里会让每处都重复一遍。
///
/// 这个模块只做一件事：把 `**强调**` 这样的标记翻成带粗体的富文本。
/// **刻意只支持这一种标记**——产品文案不是 Markdown 文档，
/// 支持越多语法，文案作者越容易写出 UI 里渲染不对的东西。
enum InlineText {

    private static let pattern = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")

    static func attributed(_ raw: String,
                           font: NSFont,
                           color: NSColor,
                           boldFont: NSFont? = nil) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let result = NSMutableAttributedString(string: raw, attributes: base)

        let ns = raw as NSString
        let matches = pattern.matches(in: raw, range: NSRange(location: 0, length: ns.length))

        // 从后往前替换，避免前面的修改影响后面的 range
        for m in matches.reversed() {
            let full = m.range
            let inner = m.range(at: 1)
            let emphasized = ns.substring(with: inner)
            let bf = boldFont ?? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            let replacement = NSAttributedString(string: emphasized, attributes: [
                .font: bf, .foregroundColor: color,
            ])
            result.replaceCharacters(in: full, with: replacement)
        }
        return result
    }

    /// 生成一个已经处理过强调标记的标签。
    static func label(_ raw: String,
                      font: NSFont,
                      color: NSColor,
                      wrapping: Bool,
                      maxWidth: CGFloat) -> NSTextField {
        let field = wrapping
            ? NSTextField(wrappingLabelWithString: "")
            : NSTextField(labelWithString: "")
        field.attributedStringValue = attributed(raw, font: font, color: color)
        field.preferredMaxLayoutWidth = maxWidth
        field.lineBreakMode = .byWordWrapping
        return field
    }
}
