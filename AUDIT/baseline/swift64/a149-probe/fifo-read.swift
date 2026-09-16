import Foundation
let url = URL(fileURLWithPath: "/tmp/a149/probe.fifo")
let started = ContinuousClock.now
do {
    let data = try Data(contentsOf: url)
    print("read \(data.count) bytes after \(started.duration(to: .now))")
} catch {
    print("threw after \(started.duration(to: .now)): \(error.localizedDescription)")
}
