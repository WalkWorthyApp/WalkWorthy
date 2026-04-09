import UIKit

/// Design scaling utility for proportional layout across all iPhone models.
/// Reference device: iPhone 17 Pro Max (440pt width).
enum DesignScale {
    static let referenceWidth: CGFloat = 440

    static var factor: CGFloat {
        let screenWidth: CGFloat = {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else { return referenceWidth }
            let bounds = scene.screen.bounds
            return min(bounds.width, bounds.height)
        }()
        return screenWidth / referenceWidth
    }
}

/// Scale a point value proportionally to the current device screen width.
func scaled(_ value: CGFloat) -> CGFloat {
    value * DesignScale.factor
}
