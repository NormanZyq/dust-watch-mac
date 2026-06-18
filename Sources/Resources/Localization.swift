import Foundation

/// Lightweight localization helper to keep string formatting concise.
///
/// - Parameters:
///   - key: Lookup key in Localizable.strings.
///   - comment: Optional comment for developers/linters.
///   - args: Optional format args for `%@`, `%d`, `%.1f`, etc.
func L(_ key: String, comment: String = "", _ args: CVarArg...) -> String {
    let template = NSLocalizedString(key, comment: comment)
    if args.isEmpty {
        return template
    }
    return String(format: template, locale: Locale.current, arguments: args)
}
