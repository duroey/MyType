import XCTest
@testable import Type4Me

final class CmuxSessionStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var sessionFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sessionFileURL = tempRoot.appendingPathComponent("session-com.cmuxterm.app.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    func testLoadSnapshotReturnsOnlyUnreadTerminalPanelsSortedByNewestAgentNotification() throws {
        try writeSessionJSON("""
        {
          "windows": [
            {
              "windowId": "window-1",
              "tabManager": {
                "selectedWorkspaceIndex": 0,
                "workspaces": [
                  {
                    "workspaceId": "workspace-old",
                    "currentDirectory": "/work/old",
                    "focusedPanelId": "panel-old",
                    "panels": [
                      {
                        "id": "panel-old",
                        "type": "terminal",
                        "title": "Old Agent",
                        "directory": "/work/old",
                        "ttyName": "ttys001",
                        "hasUnreadIndicator": true,
                        "notifications": [
                          {
                            "id": "notice-old",
                            "title": "Codex",
                            "body": "旧的 agent 回复",
                            "isRead": false,
                            "createdAt": 10
                          }
                        ]
                      },
                      {
                        "id": "panel-read",
                        "type": "terminal",
                        "title": "Read Agent",
                        "directory": "/work/read",
                        "ttyName": "ttys002",
                        "hasUnreadIndicator": false,
                        "notifications": [
                          {
                            "id": "notice-read",
                            "title": "Codex",
                            "body": "已经读过的回复",
                            "isRead": true,
                            "createdAt": 30
                          }
                        ]
                      },
                      {
                        "id": "panel-browser",
                        "type": "browser",
                        "title": "Docs",
                        "hasUnreadIndicator": true,
                        "notifications": []
                      }
                    ]
                  },
                  {
                    "workspaceId": "workspace-new",
                    "currentDirectory": "/work/new",
                    "focusedPanelId": "panel-new",
                    "panels": [
                      {
                        "id": "panel-new",
                        "type": "terminal",
                        "title": "New Agent",
                        "directory": "/work/new",
                        "ttyName": "ttys003",
                        "hasUnreadIndicator": false,
                        "notifications": [
                          {
                            "id": "notice-new",
                            "title": "Codex",
                            "body": "最新的 agent 回复",
                            "isRead": false,
                            "createdAt": 20
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
        """)
        let store = CmuxSessionStore(sessionFileURL: sessionFileURL, commandClient: nil)

        let snapshot = store.loadSnapshot()

        XCTAssertEqual(snapshot.terminalSurfaceCount, 3)
        XCTAssertEqual(snapshot.terminalSurfaces.map(\.panelID), ["panel-read", "panel-new", "panel-old"])
        XCTAssertEqual(snapshot.waitingSurfaces.map(\.panelID), ["panel-new", "panel-old"])
        XCTAssertEqual(snapshot.waitingSurfaces.first?.latestMessage, "最新的 agent 回复")
        XCTAssertEqual(snapshot.waitingSurfaces.first?.target.workspaceID, "workspace-new")
        XCTAssertEqual(snapshot.waitingSurfaces.first?.target.surfaceID, "panel-new")
        XCTAssertEqual(snapshot.waitingSurfaces.first?.target.tty, "/dev/ttys003")
    }

    func testLoadSnapshotUsesRPCForLiveTerminalSurfaces() throws {
        try writeSessionJSON("""
        {
          "windows": [
            {
              "tabManager": {
                "selectedWorkspaceIndex": 0,
                "workspaces": [
                  {
                    "workspaceId": "workspace-file",
                    "currentDirectory": "/file/waiting",
                    "focusedPanelId": "panel-file",
                    "panels": [
                      {
                        "id": "panel-file",
                        "type": "terminal",
                        "title": "File Waiting",
                        "directory": "/file/waiting",
                        "hasUnreadIndicator": true,
                        "notifications": [
                          {"body": "file waiting reply", "isRead": false, "createdAt": 30}
                        ]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
        """)
        let commandClient = CmuxCommandClient(
            executableURLProvider: { URL(fileURLWithPath: "/bin/echo") },
            rpcRunner: { method, params in
                switch method {
                case "window.list":
                    return [
                        "windows": [
                            [
                                "id": "window-uuid",
                                "ref": "window:1",
                                "key": true,
                            ],
                        ],
                    ]
                case "workspace.list":
                    XCTAssertEqual(params["window_id"] as? String, "window-uuid")
                    return [
                        "window_id": "window-uuid",
                        "window_ref": "window:1",
                        "workspaces": [
                            [
                                "id": "workspace-live",
                                "ref": "workspace:4",
                                "title": "VoiceInterface",
                                "current_directory": "/rpc/voice",
                                "latest_conversation_message": "agent latest reply",
                                "latest_submitted_at": "2026-06-12T04:19:08.839Z",
                                "selected": true,
                            ],
                        ],
                    ]
                case "debug.terminals":
                    return [
                        "terminals": [
                            [
                                "window_id": "window-uuid",
                                "window_ref": "window:1",
                                "workspace_id": "workspace-live",
                                "workspace_ref": "workspace:4",
                                "workspace_selected": true,
                                "surface_id": "surface-live",
                                "surface_ref": "surface:8",
                                "surface_title": "Live Agent",
                                "surface_focused": true,
                                "current_directory": "/rpc/voice",
                                "tty": "ttys005",
                                "mapped": true,
                            ],
                        ],
                    ]
                default:
                    XCTFail("Unexpected cmux RPC method \(method)")
                    return nil
                }
            }
        )
        let store = CmuxSessionStore(sessionFileURL: sessionFileURL, commandClient: commandClient)

        let snapshot = store.loadSnapshot()

        XCTAssertEqual(snapshot.terminalSurfaceCount, 1)
        XCTAssertEqual(snapshot.terminalSurfaces.map(\.panelID), ["surface-live"])
        XCTAssertEqual(snapshot.terminalSurfaces.first?.workspaceID, "workspace-live")
        XCTAssertEqual(snapshot.terminalSurfaces.first?.directory, "/rpc/voice")
        XCTAssertEqual(snapshot.terminalSurfaces.first?.latestMessage, "agent latest reply")
        XCTAssertEqual(snapshot.terminalSurfaces.first?.target.windowID, "window-uuid")
        XCTAssertEqual(snapshot.terminalSurfaces.first?.target.surfaceID, "surface-live")
        XCTAssertEqual(snapshot.terminalSurfaces.first?.target.tty, "/dev/ttys005")
        XCTAssertEqual(snapshot.focusedSurface?.panelID, "surface-live")
        XCTAssertEqual(snapshot.waitingSurfaces.map(\.panelID), ["panel-file"])
    }

    private func writeSessionJSON(_ json: String) throws {
        try json.data(using: .utf8)?.write(to: sessionFileURL)
    }
}
