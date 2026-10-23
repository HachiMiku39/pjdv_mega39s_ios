import Foundation
AppLanguage.configure(available:["zh-Hans","zh-Hant","ja"])
let cases = [("en", "ja"), ("en-GB", "ja"), ("ja", "ja"), ("jp", "ja"), ("ko", "ja"), ("zh-Hans", "zh-Hans"), ("zh-Hant", "zh-Hant"), ("zh-TW", "zh-Hant")]
for (selection, expected) in cases {
    precondition(AppLanguage.gameLanguageCode(selection) == expected)
    precondition(AppLanguage.supportedLanguage(selection) == expected)
    precondition(expected.utf8.count <= 7)
}
precondition(AppLanguage.available.map { $0.0 } == ["zh-Hans", "zh-Hant", "ja"])
print("PASS: selectable host locales match complete JP game UI sets; incomplete locales fall back consistently")
