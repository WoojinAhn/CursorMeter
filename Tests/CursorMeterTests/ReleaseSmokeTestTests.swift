import XCTest
@testable import CursorMeter

@MainActor
final class ReleaseSmokeTestTests: XCTestCase {
    func testExplicitSmokeArgumentsSelectEverySupportedScenario() throws {
        for scenario in ReleaseSmokeTest.Scenario.allCases {
            let parsed = try XCTUnwrap(ReleaseSmokeTest.Configuration.parse(arguments: [
                "CursorMeter", "--release-smoke-test", scenario.rawValue, "/tmp/smoke-result.json", "test-run"
            ]))
            XCTAssertEqual(parsed.scenario, scenario)
            XCTAssertEqual(parsed.resultURL.path, "/tmp/smoke-result.json")
            XCTAssertEqual(parsed.runID, "test-run")
        }
    }

    func testNormalLaunchHasNoSmokeConfiguration() throws {
        XCTAssertNil(try ReleaseSmokeTest.Configuration.parse(arguments: ["CursorMeter"]))
    }

    func testMalformedSmokeArgumentsNeverFallThroughToRealServices() {
        for arguments in [
            ["CursorMeter", "--release-smoke-test"],
            ["CursorMeter", "--release-smoke-test=startup"],
            ["CursorMeter", "--release-smoke-test", "unknown", "/tmp/result.json", "run"],
            ["CursorMeter", "--release-smoke-test", "startup", "relative.json", "run"],
            ["CursorMeter", "--release-smoke-test", "startup", "/tmp/result.json", ""],
            ["CursorMeter", "--release-smoke-test", "startup", "/tmp/result.json", "run", "extra"]
        ] {
            XCTAssertThrowsError(try ReleaseSmokeTest.Configuration.parse(arguments: arguments))
        }
    }

    func testStartupCompletesTwoRealRefreshesAndCollections() async throws {
        try await verify(.startup)
    }

    func testBonusStartupValidatesReconciliationAndTodayHighlight() async throws {
        try await verify(.bonus)
    }

    func testMissingStartupCannotProducePassingReceipt() async {
        let smoke = ReleaseSmokeTest(configuration: .init(scenario: .startup,
            resultURL: URL(fileURLWithPath: "/tmp/unused-smoke-result.json"), runID: "missing-startup"))
        do {
            _ = try await smoke.run(startup: nil)
            XCTFail("A run without the real startup refresh must not pass")
        } catch { }
    }

    private func verify(_ scenario: ReleaseSmokeTest.Scenario) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = directory.appendingPathComponent("result.json")
        let smoke = ReleaseSmokeTest(configuration: .init(scenario: scenario, resultURL: resultURL, runID: "fixture-run"))
        var credentialLoads = 0
        let load = smoke.viewModel.keychainLoadHandler
        smoke.viewModel.keychainLoadHandler = { credentialLoads += 1; return try load() }
        let report = try await smoke.run(startup: smoke.viewModel.checkExistingSession())
        XCTAssertEqual(credentialLoads, 1)
        XCTAssertEqual(report.completedRefreshes, 2)
        XCTAssertEqual(report.completedCollections, 2)
        XCTAssertEqual(report.todayCursorPercent, 10)
        XCTAssertEqual(report.todayOtherPercent, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultURL.path), "Validation must finish before receipt publication")
        try smoke.write(report)
        let decoded = try JSONDecoder().decode(ReleaseSmokeTest.Report.self, from: Data(contentsOf: resultURL))
        XCTAssertEqual(decoded.schema, 1)
        XCTAssertEqual(decoded.runID, "fixture-run")
        XCTAssertEqual(decoded.scenario, scenario.rawValue)
        XCTAssertEqual(decoded.status, "passed")
        XCTAssertThrowsError(try smoke.write(report), "An existing receipt must never be reused or overwritten")
    }

}
