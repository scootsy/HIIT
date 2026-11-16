import Foundation

/// The whole test "framework": a failed check prints why and exits non-zero,
/// which is what fails the CI step. These checks cover the app's pure logic
/// (plan generation, progression, model selection) — the files that compile
/// without UIKit — so they run in seconds on any machine with a Swift
/// toolchain. See run.sh.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func expectClose(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 0.0001) {
    expect(abs(actual - expected) <= tolerance, "\(message) (got \(actual), expected \(expected))")
}
