// A155 probe — the drain order the certificate store used, reproduced on its own.
//
// The store's own runner read stdout to EOF and only then looked at stderr. This is that order, run
// against a child that fills the error pipe (>64 KB) before it writes a byte of stdout: if the order
// deadlocks, this process never prints and the `timeout` around it is what ends it. Nothing here imports
// the package — it is Foundation's `Process` and `Pipe` doing exactly what the old code did.

import Foundation

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sh")
process.arguments = [
    "-c",
    "head -c 200000 /dev/zero | tr '\\0' 'e' 1>&2; head -c 10 /dev/zero | tr '\\0' 'o'",
]
let out = Pipe()
let err = Pipe()
process.standardOutput = out
process.standardError = err
try process.run()

// The old order, exactly.
let output = out.fileHandleForReading.readDataToEndOfFile()
let errorData = err.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
print("completed: stdout \(output.count) bytes, stderr \(errorData.count) bytes")
