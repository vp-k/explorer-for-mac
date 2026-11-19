import Foundation

/// Core 문구(오류, "- 복사본" 같은 이름 규칙). 한국어 원문이 키이고 영어는 Resources/en.lproj/Core.strings 에 둔다.
/// 번역이 없거나 테스트처럼 앱 번들 밖에서 실행하면 원문을 그대로 쓴다.
func CL(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: "Core")
}

func CL(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: CL(key), locale: Locale.current, arguments: arguments)
}
