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

        print("RedactionTests: \(cases.count + 1) 项通过")
    }
}
