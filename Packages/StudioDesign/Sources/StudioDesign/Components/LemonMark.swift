import SwiftUI

/// The LemonSeed mark: a house of two walls and a roof with a seedling and
/// three seeds inside, on a transparent background, so it sits on light and
/// dark themes alike. The image is Resources/Brand.xcassets/LemonSeedMark,
/// rendered from Brand/LemonSeedMark.svg (the app icon is the same house).
public struct LemonMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public var body: some View {
        Image("LemonSeedMark", bundle: .module)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
