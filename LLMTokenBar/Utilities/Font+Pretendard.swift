import SwiftUI

extension Font {
    static func pretendard(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("PretendardVariable", size: size).weight(weight)
    }

    static func pretendardMonospaced(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("PretendardVariable", size: size).weight(weight).monospacedDigit()
    }
}
