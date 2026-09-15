import Foundation
import Metal
let path = CommandLine.arguments[1]
guard let device = MTLCreateSystemDefaultDevice() else { print("no device"); exit(1) }
do {
    let library = try device.makeLibrary(URL: URL(fileURLWithPath: path))
    let names = library.functionNames
    print("functions: \(names.count)")
    print("steel: \(names.filter { $0.contains("steel") }.count)")
    print("first: \(names.prefix(3).joined(separator: ", "))")
} catch {
    print("FAILED: \(error)")
    exit(1)
}
