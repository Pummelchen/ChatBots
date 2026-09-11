// ChatBotsApp — the text-size indicator
//
// ⌘+ and ⌘− have no other visible effect, so without feedback it is hard to tell whether a
// key press registered — especially at the ends of the range where nothing happens. This is
// the overlay macOS shows for its own text-size keys: the new size, then gone.

import SwiftUI

struct ZoomHUD: View {
    let percent: Int
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "textformat.size")
                .font(.system(size: 30))
            Text("\(percent)%")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(palette.text)
        .frame(width: 132, height: 104)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .shadow(radius: 18)
        .allowsHitTesting(false)
    }
}
