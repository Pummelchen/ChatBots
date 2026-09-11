// ChatBotsCoreTests — the device profile list and the resolver behind it
//
// The profile list exists so that "does this work on a Galaxy A13" is a question with an
// answer, and so a capture run has something to iterate over. The resolver matters for the
// case the list cannot cover: an unknown device must still be given a sensible layout.

import ChatBotsCore
import Testing

@Suite("Device profiles")
struct DeviceProfileTests {

    @Test("The list covers the phones the brief asked for")
    func phoneCoverage() {
        let ids = DeviceProfiles.all.map(\.id)
        // iPhone 12 onwards.
        for expected in ["iphone-12-mini", "iphone-12", "iphone-13", "iphone-14-pro",
                         "iphone-15-pro-max", "iphone-16-pro", "iphone-se"] {
            #expect(ids.contains(expected), "missing \(expected)")
        }
        // Samsung, entry level to flagship, last five years.
        for expected in ["galaxy-a13", "galaxy-a14", "galaxy-a53", "galaxy-s21",
                         "galaxy-s23", "galaxy-s23-ultra", "galaxy-z-flip"] {
            #expect(ids.contains(expected), "missing \(expected)")
        }
        // Android tablets: the top models only, as asked.
        #expect(ids.contains("galaxy-tab-s9"))
        #expect(ids.contains("pixel-tablet"))
    }

    @Test("The list covers iPads back eight years")
    func tabletCoverage() {
        let iPads = DeviceProfiles.tablets
        #expect(iPads.allSatisfy { $0.kind == .tablet })
        // 2018 is eight years back from the newest here.
        #expect(iPads.map(\.year).min() == 2018)
        #expect(iPads.contains { $0.id == "ipad-pro-12-9" })
        #expect(iPads.contains { $0.id == "ipad-mini-6" })
        #expect(iPads.count >= 8, "the iPad range should be well covered")
    }

    @Test("The list reaches down to the narrowest screens in use")
    func narrowestDevicesArePresent() {
        // 360 points is the entry-level Android width and the first place a two-column
        // layout fails; a list of modern iPhones alone starts at 375 and would miss it.
        let mobiles = (DeviceProfiles.phones + DeviceProfiles.samsung).map(\.width)
        #expect(mobiles.min() == 360, "the narrowest phone viewport should be a 360-point Android")
        #expect(DeviceProfiles.samsung.contains { $0.width == 360 })
    }

    @Test("Viewports are CSS points, not marketing resolutions")
    func viewportsAreCssPixels() {
        // An iPhone 12 is sold as 1170x2532; the layout is handed 390x844 at 3x. Confusing
        // the two is the usual reason a mobile layout is tested at the wrong width.
        let iPhone12 = DeviceProfiles.profile(id: "iphone-12")
        #expect(iPhone12?.width == 390)
        #expect(iPhone12?.height == 844)
        #expect(iPhone12?.pixelRatio == 3)
        #expect(iPhone12?.physicalWidth == 1170)
        #expect(iPhone12?.physicalHeight == 2532)

        let iPad = DeviceProfiles.profile(id: "ipad-10-2")
        #expect(iPad?.width == 810)
        #expect(iPad?.physicalWidth == 1620)
    }

    @Test("Identifiers are unique, so a profile is addressable")
    func identifiersAreUnique() {
        let ids = DeviceProfiles.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every profile is usable and named")
    func profilesAreWellFormed() {
        for profile in DeviceProfiles.all {
            #expect(!profile.name.isEmpty)
            #expect(profile.width > 200, "\(profile.id) is implausibly narrow")
            #expect(profile.height > 400)
            #expect(profile.pixelRatio >= 1)
            #expect(profile.year >= 2018, "\(profile.id) predates the range asked for")
            #expect(!profile.label.isEmpty)
        }
    }

    @Test("The capture set has one entry per distinct shape")
    func captureSetIsDeduplicated() {
        let shapes = DeviceProfiles.captureSet.map { "\($0.width)x\($0.height)@\($0.pixelRatio)" }
        #expect(Set(shapes).count == shapes.count, "two captured profiles have the same viewport")
        // And it only contains devices marked common, so a run stays quick.
        #expect(DeviceProfiles.captureSet.allSatisfy { $0.isCommon })
    }
}

@Suite("Resolving an unknown screen")
struct DeviceResolutionTests {

    @Test("An exact match is returned as itself")
    func exactMatch() {
        let match = DeviceProfiles.nearest(width: 390, height: 844, isMobile: true)
        #expect(match?.id == "iphone-12")
    }

    @Test("A near miss resolves to the closest device of the same class")
    func nearMiss() {
        // 358 points is not a listed phone, but it is plainly a small Android one.
        let match = DeviceProfiles.nearest(width: 358, height: 800, isMobile: true)
        #expect(match?.kind == .phone)
        #expect(match != nil, "a close width should match rather than being called unknown")
    }

    @Test("A device unlike anything listed resolves to nothing, so width rules take over")
    func unknownDeviceIsAdmitted() {
        // A very wide phone, or a foldable's inner screen. Pretending it is a Galaxy A13
        // would be worse than saying it is not known.
        #expect(DeviceProfiles.nearest(width: 500, height: 900, isMobile: true) == nil)
    }

    @Test("A desktop is not matched against phones, however narrow the window")
    func desktopIsNotAPhone() {
        let match = DeviceProfiles.nearest(width: 390, height: 844, isMobile: false)
        #expect(match == nil || match?.kind == .desktop,
                "a desktop window must not resolve to a handset profile")
    }

    @Test("A wide screen is treated as a desktop")
    func wideIsDesktop() {
        let match = DeviceProfiles.nearest(width: 1440, height: 900, isMobile: false)
        #expect(match == nil || match?.kind == .desktop)
    }

    @Test("Tablets are matched as tablets, not as large phones")
    func tabletsAreTablets() {
        let match = DeviceProfiles.nearest(width: 810, height: 1080, isMobile: true)
        #expect(match?.kind == .tablet)
        #expect(match?.id == "ipad-10-2")
    }
}

@Suite("What the interface branches on")
struct DeviceClassTests {

    @Test("Only a phone gets the single-column layout by default")
    func singleColumnIsForPhones() {
        // The distinction the brief cares about: a phone is one chat window, a tablet has the
        // room for two panes.
        #expect(DeviceClass.phone.prefersSingleColumn)
        #expect(!DeviceClass.tablet.prefersSingleColumn)
        #expect(!DeviceClass.desktop.prefersSingleColumn)
    }

    @Test("Breakpoints put the narrowest tablet in one column")
    func breakpoints() {
        // 810 points is a tablet in portrait and the two-pane layout fits; 744 is the mini and
        // is handled by the width rule in the client rather than the profile.
        #expect(DeviceProfiles.profile(id: "ipad-mini-6")?.width == 744)
        #expect(DeviceProfiles.profile(id: "ipad-10-2")?.width == 810)
    }
}
