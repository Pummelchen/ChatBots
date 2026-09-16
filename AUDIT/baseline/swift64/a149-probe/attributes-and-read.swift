import Foundation
let dir = URL(fileURLWithPath: "/tmp/a149")
let link = dir.appending(path: "gone.txt")
try? FileManager.default.removeItem(at: link)
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appending(path: "nothing.txt"))
do {
    let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
    print("attributes: type=\(attrs[.type] ?? "?") size=\(attrs[.size] ?? "?")")
} catch {
    print("attributes threw: \(error.localizedDescription)")
}
do { let d = try Data(contentsOf: link); print("read \(d.count) bytes") } catch { print("read threw: \(error.localizedDescription)") }
