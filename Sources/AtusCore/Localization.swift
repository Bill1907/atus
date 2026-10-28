import Foundation

/// Localized UI text. Keys are the English strings themselves, so English needs no
/// table and any run without the app bundle (tests, `swift run`) shows English.
/// Other languages come from `<lang>.lproj/Localizable.strings` in the app bundle,
/// picked by macOS from the user's preferred languages.
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Localized format string (`%@` for strings, `%ld` for integers) filled with `arguments`.
public func L(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: L(format), arguments: arguments)
}

/// The UI language with the user's region, so dates match the surrounding text even
/// when the system language differs from the app's (e.g. English UI, Korean region).
public var appLocale: Locale {
    let language = Bundle.main.preferredLocalizations.first ?? "en"
    guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
    return Locale(identifier: "\(language)_\(region)")
}
