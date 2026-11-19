import Foundation

/// 화면 문구. 한국어 원문이 키이고 영어는 Resources/en.lproj/Localizable.strings 에 둔다.
/// 번역이 없거나 번들 밖에서 실행하면 원문(한국어)을 그대로 쓴다.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

/// 서식 문구. 키에 %@, %d 같은 자리표시자를 넣는다. 영어 번역에서 순서를 바꾸려면 %1$@ 처럼 쓴다.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: arguments)
}

enum AppLanguage {
    /// 앱이 영어로 표시되는가. 시스템 언어 설정에 따라 번들이 고른 언어를 따른다.
    static let isEnglish = Bundle.main.localizedString(forKey: "__language__", value: nil, table: nil) == "en"
}
