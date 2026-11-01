import Foundation
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
task.arguments = ["python3", URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("make-icons.py").path] + Array(CommandLine.arguments.dropFirst())
try task.run(); task.waitUntilExit(); exit(task.terminationStatus)
