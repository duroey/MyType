// Host executable for the XCTest shim. It must be built under the name
// `xctest`: the app decides it is running under tests from the process name, and
// that is what routes it to the isolated test profile and credential storage.
import Foundation
import XCTest

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: xctest <bundle> <async-throws-list> [--list]\n".utf8))
    exit(2)
}
guard let bundle = Bundle(path: arguments[1]), bundle.load() else {
    FileHandle.standardError.write(Data("failed to load test bundle \(arguments[1])\n".utf8))
    exit(2)
}
let listed = (try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? ""
let asyncThrowing = Set(listed.split(separator: "\n").map(String.init))
let filter = Set(
    (ProcessInfo.processInfo.environment["XCT_FILTER"] ?? "").split(separator: ",").map(String.init)
)
exit(XCTShimRunner.main(
    asyncThrowing: asyncThrowing,
    filter: filter,
    listOnly: arguments.contains("--list")
))
