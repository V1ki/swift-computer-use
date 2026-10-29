import Foundation
import Darwin

// main.swift 使用顶层入口，不与 @main 混用。
let exitCode = await CUACommandLine.run(Array(CommandLine.arguments.dropFirst()))
exit(exitCode)
