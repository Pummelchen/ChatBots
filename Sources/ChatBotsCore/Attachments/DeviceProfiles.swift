// ChatBotsCore — screen profiles for the phones and tablets that will load the web interface
//
// The layout does not need to know the *name* of a device, only its shape: how wide the
// viewport is in CSS pixels, how many physical pixels that is, and whether it is held in a
// hand or on a lap. But naming the devices is what makes the profile list verifiable —
// "does this work on a Galaxy A13" is a question someone can answer, where "does this work
// at 360×800" is not — and it is what the capture harness iterates over.
//
// Sizes are the **CSS viewport** in portrait, which is not the marketing resolution: a
// 1170×2532 iPhone reports about 390×844 because the device pixel ratio is 3. Getting this
// wrong is the usual reason a mobile layout is tested at the wrong width.
//
// The list deliberately spans the *narrowest* devices as well as the flagship ones. A
// 320-point iPhone SE or a 360-point Galaxy A-series is where a layout breaks, not on the
// latest Pro Max.

import Foundation

/// What kind of screen this is, which is what the interface actually branches on.
public enum DeviceClass: String, Sendable, Codable, CaseIterable, Identifiable {
    case phone
    case tablet
    case desktop

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .desktop: "Desktop"
        }
    }

    /// Phones get one column — a WhatsApp-style single conversation — because two panes at
    /// 360 points are about fifteen characters each, which is not a conversation.
    public var prefersSingleColumn: Bool {
        self == .phone
    }
}

/// A screen the interface may be loaded on.
public struct DeviceProfile: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let kind: DeviceClass
    /// Viewport in CSS pixels, portrait. What the layout is actually handed.
    public let width: Int
    public let height: Int
    /// Physical pixels per CSS pixel, for the capture harness.
    public let pixelRatio: Double
    /// Year of introduction, so the list can be reasoned about as "the last N years".
    public let year: Int
    /// Whether this is still a device people commonly carry. Kept so the capture set can be
    /// the common cases while the resolver still knows the old ones.
    public let isCommon: Bool

    public init(
        id: String, name: String, kind: DeviceClass, width: Int, height: Int,
        pixelRatio: Double, year: Int, isCommon: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.width = width
        self.height = height
        self.pixelRatio = pixelRatio
        self.year = year
        self.isCommon = isCommon
    }

    public var physicalWidth: Int { Int((Double(width) * pixelRatio).rounded()) }
    public var physicalHeight: Int { Int((Double(height) * pixelRatio).rounded()) }

    /// Short description for a capture report or a debug label.
    public var label: String { "\(name) — \(width)×\(height) @\(pixelRatio)x" }
}

public enum DeviceProfiles {

    // MARK: - iPhone, from the 12 onwards
    //
    // The mini is the important one here: at 375 points it is the narrowest modern iPhone and
    // the first place a two-column layout fails.

    public static let phones: [DeviceProfile] = [
        // iPhone 12 family (2020)
        DeviceProfile(id: "iphone-12-mini", name: "iPhone 12 mini", kind: .phone,
                      width: 375, height: 812, pixelRatio: 3, year: 2020),
        DeviceProfile(id: "iphone-12", name: "iPhone 12 / 12 Pro", kind: .phone,
                      width: 390, height: 844, pixelRatio: 3, year: 2020, isCommon: true),
        DeviceProfile(id: "iphone-12-pro-max", name: "iPhone 12 Pro Max", kind: .phone,
                      width: 428, height: 926, pixelRatio: 3, year: 2020),
        // iPhone 13 (2021)
        DeviceProfile(id: "iphone-13-mini", name: "iPhone 13 mini", kind: .phone,
                      width: 375, height: 812, pixelRatio: 3, year: 2021),
        DeviceProfile(id: "iphone-13", name: "iPhone 13 / 14", kind: .phone,
                      width: 390, height: 844, pixelRatio: 3, year: 2021, isCommon: true),
        DeviceProfile(id: "iphone-13-pro-max", name: "iPhone 13 Pro Max", kind: .phone,
                      width: 428, height: 926, pixelRatio: 3, year: 2021),
        // iPhone 14 (2022)
        DeviceProfile(id: "iphone-14-plus", name: "iPhone 14 Plus", kind: .phone,
                      width: 428, height: 926, pixelRatio: 3, year: 2022),
        DeviceProfile(id: "iphone-14-pro", name: "iPhone 14 Pro", kind: .phone,
                      width: 393, height: 852, pixelRatio: 3, year: 2022),
        DeviceProfile(id: "iphone-14-pro-max", name: "iPhone 14 Pro Max", kind: .phone,
                      width: 430, height: 932, pixelRatio: 3, year: 2022),
        // iPhone 15 (2023)
        DeviceProfile(id: "iphone-15", name: "iPhone 15 / 16", kind: .phone,
                      width: 393, height: 852, pixelRatio: 3, year: 2023, isCommon: true),
        DeviceProfile(id: "iphone-15-plus", name: "iPhone 15 Plus / 16 Plus", kind: .phone,
                      width: 430, height: 932, pixelRatio: 3, year: 2023),
        DeviceProfile(id: "iphone-15-pro", name: "iPhone 15 Pro", kind: .phone,
                      width: 393, height: 852, pixelRatio: 3, year: 2023),
        DeviceProfile(id: "iphone-15-pro-max", name: "iPhone 15 Pro Max / 16 Pro Max", kind: .phone,
                      width: 430, height: 932, pixelRatio: 3, year: 2023),
        // iPhone 16 (2024)
        DeviceProfile(id: "iphone-16-pro", name: "iPhone 16 Pro", kind: .phone,
                      width: 402, height: 874, pixelRatio: 3, year: 2024, isCommon: true),
        // The small-screen baseline, kept because it is still the narrowest thing in use.
        DeviceProfile(id: "iphone-se", name: "iPhone SE (2nd/3rd gen)", kind: .phone,
                      width: 375, height: 667, pixelRatio: 2, year: 2020),
    ]

    // MARK: - Samsung Galaxy, entry level to flagship, last five years

    public static let samsung: [DeviceProfile] = [
        // Entry level — the A-series is where narrow viewports actually appear in the wild.
        DeviceProfile(id: "galaxy-a13", name: "Galaxy A13", kind: .phone,
                      width: 360, height: 800, pixelRatio: 3, year: 2022, isCommon: true),
        DeviceProfile(id: "galaxy-a14", name: "Galaxy A14 / A15", kind: .phone,
                      width: 360, height: 800, pixelRatio: 3, year: 2023, isCommon: true),
        DeviceProfile(id: "galaxy-a23", name: "Galaxy A23", kind: .phone,
                      width: 360, height: 800, pixelRatio: 3, year: 2022),
        DeviceProfile(id: "galaxy-a33", name: "Galaxy A33 / A34", kind: .phone,
                      width: 385, height: 854, pixelRatio: 3, year: 2022),
        DeviceProfile(id: "galaxy-a53", name: "Galaxy A53 / A54", kind: .phone,
                      width: 412, height: 915, pixelRatio: 2.625, year: 2022, isCommon: true),
        DeviceProfile(id: "galaxy-a73", name: "Galaxy A73", kind: .phone,
                      width: 412, height: 915, pixelRatio: 2.625, year: 2022),
        // Mid range
        DeviceProfile(id: "galaxy-s20-fe", name: "Galaxy S20 FE", kind: .phone,
                      width: 412, height: 915, pixelRatio: 2.625, year: 2020),
        DeviceProfile(id: "galaxy-s21", name: "Galaxy S21 / S22", kind: .phone,
                      width: 360, height: 800, pixelRatio: 3, year: 2021),
        DeviceProfile(id: "galaxy-s21-ultra", name: "Galaxy S21 Ultra", kind: .phone,
                      width: 384, height: 854, pixelRatio: 3.5, year: 2021),
        // Flagship
        DeviceProfile(id: "galaxy-s22-ultra", name: "Galaxy S22 Ultra", kind: .phone,
                      width: 384, height: 854, pixelRatio: 3.5, year: 2022),
        DeviceProfile(id: "galaxy-s23", name: "Galaxy S23 / S24", kind: .phone,
                      width: 360, height: 780, pixelRatio: 3, year: 2023, isCommon: true),
        DeviceProfile(id: "galaxy-s23-ultra", name: "Galaxy S23 Ultra / S24 Ultra", kind: .phone,
                      width: 384, height: 854, pixelRatio: 3.5, year: 2023, isCommon: true),
        DeviceProfile(id: "galaxy-z-flip", name: "Galaxy Z Flip 5", kind: .phone,
                      width: 360, height: 880, pixelRatio: 3, year: 2023),
        DeviceProfile(id: "galaxy-note20", name: "Galaxy Note 20 Ultra", kind: .phone,
                      width: 412, height: 915, pixelRatio: 3.5, year: 2020),
    ]

    // MARK: - iPad, last eight years

    public static let tablets: [DeviceProfile] = [
        DeviceProfile(id: "ipad-mini-5", name: "iPad mini 5", kind: .tablet,
                      width: 768, height: 1024, pixelRatio: 2, year: 2019),
        DeviceProfile(id: "ipad-9-7", name: "iPad 9.7\" (5th/6th gen)", kind: .tablet,
                      width: 768, height: 1024, pixelRatio: 2, year: 2018),
        DeviceProfile(id: "ipad-10-2", name: "iPad 10.2\" (7th–9th gen)", kind: .tablet,
                      width: 810, height: 1080, pixelRatio: 2, year: 2019, isCommon: true),
        DeviceProfile(id: "ipad-mini-6", name: "iPad mini 6", kind: .tablet,
                      width: 744, height: 1133, pixelRatio: 2, year: 2021),
        DeviceProfile(id: "ipad-air-10-5", name: "iPad Air 10.5\" (3rd gen)", kind: .tablet,
                      width: 834, height: 1112, pixelRatio: 2, year: 2019),
        DeviceProfile(id: "ipad-air-10-9", name: "iPad Air 10.9\" (4th/5th gen)", kind: .tablet,
                      width: 820, height: 1180, pixelRatio: 2, year: 2020, isCommon: true),
        DeviceProfile(id: "ipad-10-9", name: "iPad 10.9\" (10th gen)", kind: .tablet,
                      width: 820, height: 1180, pixelRatio: 2, year: 2022),
        DeviceProfile(id: "ipad-pro-11", name: "iPad Pro 11\"", kind: .tablet,
                      width: 834, height: 1194, pixelRatio: 2, year: 2018, isCommon: true),
        DeviceProfile(id: "ipad-pro-12-9", name: "iPad Pro 12.9\"", kind: .tablet,
                      width: 1024, height: 1366, pixelRatio: 2, year: 2018, isCommon: true),
        DeviceProfile(id: "ipad-air-13", name: "iPad Air 13\" / Pro 13\"", kind: .tablet,
                      width: 1024, height: 1366, pixelRatio: 2, year: 2024),
    ]

    // MARK: - Top Android tablets only, as asked

    public static let androidTablets: [DeviceProfile] = [
        DeviceProfile(id: "galaxy-tab-s6-lite", name: "Galaxy Tab S6 Lite", kind: .tablet,
                      width: 800, height: 1280, pixelRatio: 2, year: 2020),
        DeviceProfile(id: "galaxy-tab-s7", name: "Galaxy Tab S7", kind: .tablet,
                      width: 800, height: 1280, pixelRatio: 2, year: 2020),
        DeviceProfile(id: "galaxy-tab-s8", name: "Galaxy Tab S8", kind: .tablet,
                      width: 800, height: 1280, pixelRatio: 2, year: 2022),
        DeviceProfile(id: "galaxy-tab-s9", name: "Galaxy Tab S9", kind: .tablet,
                      width: 800, height: 1280, pixelRatio: 2, year: 2023, isCommon: true),
        DeviceProfile(id: "galaxy-tab-s9-ultra", name: "Galaxy Tab S9 Ultra", kind: .tablet,
                      width: 848, height: 1360, pixelRatio: 2, year: 2023),
        DeviceProfile(id: "pixel-tablet", name: "Pixel Tablet", kind: .tablet,
                      width: 800, height: 1280, pixelRatio: 2, year: 2023),
    ]

    /// Everything, for a resolver or a capture run.
    public static let all: [DeviceProfile] =
        phones + samsung + tablets + androidTablets

    /// The set a capture run covers by default: one per distinct viewport shape, plus every
    /// device marked common. Testing two devices with identical dimensions proves nothing
    /// twice.
    public static var captureSet: [DeviceProfile] {
        var seen = Set<String>()
        return all.filter { $0.isCommon }.filter { profile in
            let key = "\(profile.width)x\(profile.height)@\(profile.pixelRatio)"
            return seen.insert(key).inserted
        }
    }

    public static func profile(id: String) -> DeviceProfile? {
        all.first { $0.id == id }
    }

    /// The best match for a live viewport, or nil when the device is not in the list.
    ///
    /// Matching is by *class and width* rather than by an exact hit, because the width is
    /// what the layout cares about and because an unknown device must still be handled well:
    /// a browser that reports 355 points is closer to the 360-point Android phones than to
    /// anything else, and the caller only needs to know which side of the breakpoints it is
    /// on. Nil means genuinely unlike anything known, which is the signal to fall back to
    /// the width-based rules.
    /// The largest viewport dimension the resolver will consider.
    ///
    /// The dimensions arrive from an unauthenticated query string (`GET /api/device?w=&h=`)
    /// on the LAN-reachable API, and the distance arithmetic below is `Int`. A height near
    /// `Int.max` overflows `abs(lhs.height - height) * 1000 + ...` and traps, which aborts
    /// the whole engine process. A CSS viewport is a few thousand points at most, so a
    /// value beyond this bound is "unlike anything known" rather than a number to compute
    /// with — and bounding it here means no caller can reach the subtractions with an
    /// arithmetic overflow however the input arrived.
    public static let maximumViewportDimension = 100_000

    public static func nearest(width: Int, height: Int, isMobile: Bool) -> DeviceProfile? {
        guard width > 0, height >= 0,
            width <= maximumViewportDimension, height <= maximumViewportDimension
        else { return nil }
        let candidateClass: DeviceClass = {
            if width >= 1000 { return .desktop }
            return isMobile ? (width >= 700 ? .tablet : .phone) : .desktop
        }()
        let candidates = all.filter { $0.kind == candidateClass }
        guard !candidates.isEmpty else { return nil }

        // Exact shape first, then closest width, then closest height.
        if let exact = candidates.first(where: { $0.width == width && $0.height == height }) {
            return exact
        }
        let ordered = candidates.sorted { lhs, rhs in
            let lhsDelta = abs(lhs.width - width) * 1000 + abs(lhs.height - height)
            let rhsDelta = abs(rhs.width - width) * 1000 + abs(rhs.height - height)
            return lhsDelta < rhsDelta
        }
        guard let closest = ordered.first else { return nil }
        // Within a tolerance, call it a match; beyond that, admit the device is unknown.
        return abs(closest.width - width) <= 24 ? closest : nil
    }
}
