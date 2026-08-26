import Foundation

@main
struct RedactionTests {
    static func main() {
        let cases: [(input: String, hidden: String, expectedMarker: String)] = [
            (
                "caffeinate command --api-key sk-test-value",
                "sk-test-value",
                "--api-key ••••"
            ),
            (
                "caffeinate command --access-token=github-test-value",
                "github-test-value",
                "--access-token=••••"
            ),
            (
                "OPENAI_API_KEY=environment-test-value caffeinate -i",
                "environment-test-value",
                "OPENAI_API_KEY=••••"
            ),
            (
                "command 'https://example.test/?token=query-test-value&mode=1'",
                "query-test-value",
                "?token=••••&mode=1"
            ),
            (
                "command https://user:userinfo-test-value@example.test/path",
                "userinfo-test-value",
                "https://user:••••@example.test/path"
            ),
            (
                "command -H 'Authorization: Bearer bearer-test-value'",
                "bearer-test-value",
                "Bearer ••••"
            )
        ]

        for testCase in cases {
            let output = CommandRedactor.redact(testCase.input)
            precondition(
                !output.contains(testCase.hidden),
                "敏感值仍然存在：\(testCase.input) -> \(output)"
            )
            precondition(
                output.contains(testCase.expectedMarker),
                "脱敏格式不符合预期：\(testCase.input) -> \(output)"
            )
        }

        let safeCommand = "caffeinate -i /usr/bin/python3 report.py --limit 15"
        precondition(
            CommandRedactor.redact(safeCommand) == safeCommand,
            "普通命令不应被修改"
        )

        let modernOutput = """
            disabled services = {
                "example.enabled" => enabled
                "example.disabled" => disabled
            }
        """
        precondition(
            SystemScanner.isServiceDisabled(label: "example.disabled", in: modernOutput),
            "应识别新版 launchctl 的 disabled 状态"
        )
        precondition(
            !SystemScanner.isServiceDisabled(label: "example.enabled", in: modernOutput),
            "不应把新版 launchctl 的 enabled 状态识别为停用"
        )

        let legacyOutput = """
            disabled services = {
                "example.old-disabled" => true
                "example.old-enabled" => false
            }
        """
        precondition(
            SystemScanner.isServiceDisabled(label: "example.old-disabled", in: legacyOutput),
            "应兼容旧版 launchctl 的 true 状态"
        )
        precondition(
            !SystemScanner.isServiceDisabled(label: "example.old-enabled", in: legacyOutput),
            "不应把旧版 launchctl 的 false 状态识别为停用"
        )

        print("Tests: \(cases.count + 5) 项通过")
    }
}
