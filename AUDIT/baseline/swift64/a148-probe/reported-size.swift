import Foundation
import ImageIO

for name in CommandLine.arguments.dropFirst() {
    let data = try! Data(contentsOf: URL(fileURLWithPath: name))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        print("\(name): no source"); continue
    }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? -1
    let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? -1
    let type = CGImageSourceGetType(source) as String? ?? "?"
    print("\(name): reported \(w)x\(h) type=\(type) bytes=\(data.count)")
}
