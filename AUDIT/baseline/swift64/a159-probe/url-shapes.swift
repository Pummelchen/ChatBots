// A159 probe — what Foundation makes of the shapes this validation has to tell apart.
//
// `url.scheme?.hasPrefix("http")` and no host check is the finding. This prints, for each shape, whether
// `URL(string:)` parses it at all, what the scheme is, what the host is, and what the current guard would
// have done — so the fix and its tests are written against measured behaviour rather than assumption.

import Foundation

func oldGuard(_ raw: String) -> Bool {
    guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return false }
    _ = url
    return true
}

let shapes = [
    "https://example.com/article",
    "http://example.com",
    "HTTP://EXAMPLE.COM/x",
    "Https://example.com",
    "httpx://example.com",
    "httpfoo://example.com",
    "http://",
    "http:",
    "http:///path",
    "https://example.com:8443/x",
    "http://user:pass@example.com/x",
    "http://127.0.0.1:1/x",
    "http://[::1]:1/x",
    "http://exa mple.com/x",
    "http://example.com/a b",
    "  https://example.com/x  ",
    "example.com/x",
    "ftp://example.com",
    "file:///etc/passwd",
    "javascript:alert(1)",
]

for shape in shapes {
    let url = URL(string: shape)
    let scheme = url?.scheme ?? "-"
    let host = url?.host() ?? "-"
    let port = url?.port.map(String.init) ?? "-"
    print(
        "raw=\(shape.debugDescription)\n"
            + "   parses=\(url != nil) scheme=\(scheme) host=\(host) port=\(port)\n"
            + "   old-guard-accepts=\(oldGuard(shape))")
}
