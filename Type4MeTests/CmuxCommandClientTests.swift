import XCTest
@testable import Type4Me

final class CmuxCommandClientTests: XCTestCase {
    func testSendArgumentAppendsLiteralNewlineEscape() {
        XCTAssertEqual(CmuxCommandClient.sendArgument(for: "Go"), "Go\\n")
        XCTAssertEqual(CmuxCommandClient.sendArgument(for: "继续"), "继续\\n")
    }

    func testFocusedSurfaceTargetParsesIdentifyPayload() {
        let payload: [String: Any] = [
            "focused": [
                "surface_type": "terminal",
                "window_id": "window-uuid",
                "workspace_id": "workspace-uuid",
                "workspace_ref": "workspace-2",
                "surface_id": "surface-uuid",
                "surface_ref": "surface-3",
            ],
        ]

        let target = CmuxCommandClient.focusedSurfaceTarget(fromIdentifyPayload: payload)

        XCTAssertEqual(
            target,
            CmuxSurfaceTarget(workspaceID: "workspace-uuid", surfaceID: "surface-uuid", tty: nil, windowID: "window-uuid")
        )
    }

    func testFocusedSurfaceTargetRequestsUUIDsAndRefs() {
        final class Recorder: @unchecked Sendable {
            var calls: [(String, [String: Any])] = []
        }
        let recorder = Recorder()
        let client = CmuxCommandClient(
            executableURLProvider: { URL(fileURLWithPath: "/bin/echo") },
            rpcRunner: { method, params in
                recorder.calls.append((method, params))
                return [
                    "focused": [
                        "surface_type": "terminal",
                        "workspace_id": "workspace-uuid",
                        "surface_id": "surface-uuid",
                    ],
                ]
            }
        )

        _ = client.focusedSurfaceTarget()

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].0, "system.identify")
        XCTAssertEqual(recorder.calls[0].1["no_caller"] as? Bool, true)
    }

    func testNewWorkspaceUsesCliCommandFlag() throws {
        final class Recorder: @unchecked Sendable {
            var rpcCalls: [(String, [String: Any])] = []
            var processCalls: [(URL, [String], [String: String])] = []
        }
        let recorder = Recorder()
        let client = CmuxCommandClient(
            executableURLProvider: { URL(fileURLWithPath: "/bin/echo") },
            processRunner: { executableURL, arguments, environment in
                recorder.processCalls.append((executableURL, arguments, environment))
                return CmuxCommandResult(stdout: "", stderr: "", terminationStatus: 0)
            },
            rpcRunner: { method, params in
                recorder.rpcCalls.append((method, params))
                if method == "window.list" {
                    return [
                        "windows": [
                            ["id": "window-uuid", "ref": "window:1", "index": 0, "key": true],
                        ],
                    ]
                }
                return [:]
            }
        )

        let accepted = client.newWorkspace(
            name: "计算机图形学",
            cwd: "/Users/example/Downloads/计算机图形学",
            command: "codex --dangerously-bypass-approvals-and-sandbox resume"
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(recorder.rpcCalls.map(\.0), ["window.list"])
        let processCall = try XCTUnwrap(recorder.processCalls.first)
        XCTAssertEqual(recorder.processCalls.count, 1)
        XCTAssertEqual(processCall.0.path, "/bin/echo")
        XCTAssertEqual(
            processCall.1,
            [
                "workspace", "create",
                "--name", "计算机图形学",
                "--cwd", "/Users/example/Downloads/计算机图形学",
                "--command", "codex --dangerously-bypass-approvals-and-sandbox resume",
                "--window", "window-uuid",
                "--focus", "true",
            ]
        )
    }

    func testNewWorkspaceLaunchesCmuxAndWaitsForWindowWhenNoWindowExists() throws {
        final class Recorder: @unchecked Sendable {
            var appLaunchCount = 0
            var sleepDurations: [TimeInterval] = []
            var rpcCalls: [(String, [String: Any])] = []
            var processCalls: [(URL, [String], [String: String])] = []
        }
        let recorder = Recorder()
        var windowListCalls = 0
        let client = CmuxCommandClient(
            executableURLProvider: { URL(fileURLWithPath: "/bin/echo") },
            processRunner: { executableURL, arguments, environment in
                recorder.processCalls.append((executableURL, arguments, environment))
                return CmuxCommandResult(stdout: "", stderr: "", terminationStatus: 0)
            },
            rpcRunner: { method, params in
                recorder.rpcCalls.append((method, params))
                if method == "window.list" {
                    windowListCalls += 1
                    if windowListCalls == 1 {
                        return ["windows": []]
                    }
                    return [
                        "windows": [
                            ["id": "window-after-launch", "key": true],
                        ],
                    ]
                }
                return [:]
            },
            appLauncher: {
                recorder.appLaunchCount += 1
                return true
            },
            sleeper: { duration in
                recorder.sleepDurations.append(duration)
            }
        )

        let accepted = client.newWorkspace(
            name: "VoiceInterface",
            cwd: "/Users/example/VoiceInterface",
            command: "codex --dangerously-bypass-approvals-and-sandbox resume"
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(recorder.appLaunchCount, 1)
        XCTAssertEqual(recorder.sleepDurations, [CmuxCommandClient.windowReadyPollInterval])
        XCTAssertEqual(recorder.rpcCalls.map(\.0), ["window.list", "window.list"])
        let processCall = try XCTUnwrap(recorder.processCalls.first)
        XCTAssertEqual(processCall.1, [
            "workspace", "create",
            "--name", "VoiceInterface",
            "--cwd", "/Users/example/VoiceInterface",
            "--command", "codex --dangerously-bypass-approvals-and-sandbox resume",
            "--window", "window-after-launch",
            "--focus", "true",
        ])
    }

    func testFocusUsesWorkspaceAndSurfaceRPC() {
        final class Recorder: @unchecked Sendable {
            var calls: [(String, [String: Any])] = []
        }
        let recorder = Recorder()
        let client = CmuxCommandClient(
            executableURLProvider: { URL(fileURLWithPath: "/bin/echo") },
            rpcRunner: { method, params in
                recorder.calls.append((method, params))
                return [:]
            }
        )

        let accepted = client.focus(
            target: CmuxSurfaceTarget(workspaceID: "workspace-uuid", surfaceID: "surface-uuid", tty: nil, windowID: "window-uuid")
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(recorder.calls.map(\.0), ["workspace.select", "surface.focus"])
        XCTAssertEqual(recorder.calls[0].1["window_id"] as? String, "window-uuid")
        XCTAssertEqual(recorder.calls[0].1["workspace_id"] as? String, "workspace-uuid")
        XCTAssertEqual(recorder.calls[1].1["window_id"] as? String, "window-uuid")
        XCTAssertEqual(recorder.calls[1].1["workspace_id"] as? String, "workspace-uuid")
        XCTAssertEqual(recorder.calls[1].1["surface_id"] as? String, "surface-uuid")
    }

    func testDebugTerminalsMatchesNormalizedTTY() {
        let payload: [String: Any] = [
            "terminals": [
                [
                    "tty": "ttys004",
                    "workspace_id": "workspace-a",
                    "surface_id": "surface-a",
                ],
                [
                    "tty": "/dev/ttys005",
                    "workspace_id": "workspace-b",
                    "surface_id": "surface-b",
                ],
            ],
        ]

        let target = CmuxCommandClient.surfaceTarget(fromDebugTerminalsPayload: payload, matchingTTY: "ttys005")

        XCTAssertEqual(target, CmuxSurfaceTarget(workspaceID: "workspace-b", surfaceID: "surface-b", tty: "/dev/ttys005"))
    }

    func testCommandEnvironmentUsesCleanSocketPath() {
        let home = URL(fileURLWithPath: "/Users/example")

        let environment = CmuxCommandClient.commandEnvironment(homeDirectory: home, userName: "example")

        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["USER"], "example")
        XCTAssertEqual(environment["LOGNAME"], "example")
        XCTAssertEqual(environment["CMUX_SOCKET_PATH"], "/Users/example/.local/state/cmux/cmux.sock")
        XCTAssertNil(environment["XPC_SERVICE_NAME"])
    }

    func testDefaultCommandTimeoutAllowsSlowSocketSendRoundTrip() {
        XCTAssertGreaterThanOrEqual(CmuxCommandClient.defaultCommandTimeoutMilliseconds, 5_000)
    }

    func testCliExecutableURLUsesResourcesBinInsideAppBundle() {
        let appURL = URL(fileURLWithPath: "/Applications/cmux.app")

        let executableURL = CmuxCommandClient.cliExecutableURL(inAppAt: appURL)

        XCTAssertEqual(executableURL.path, "/Applications/cmux.app/Contents/Resources/bin/cmux")
    }
}
