import QuartzCore

/// THE SAME CURVE THE VIEW TREE WOULD HAVE TRAVELLED ON. SwiftUI's three are springs stated as a
/// perceptual duration and a bounce, and Core Animation takes a spring in exactly those terms
/// (`CASpringAnimation(perceptualDuration:bounce:)`, macOS 14), so this is the same motion rather
/// than an approximation of it: smooth has no overshoot, snappy a little, bouncy the overshoot it is
/// named for (`MotionChoice.Curve.animation`).
///
/// SPELLED ONCE FOR BOTH FIGURES THIS BOARD HANDS TO THE RENDER SERVER, the outline and the digits
/// beside it (`FootprintSparklineLayerView`, `RollingFigureLayerView`). A second copy of these three
/// bounce values would be a board whose line and whose number overshoot by different amounts on the
/// curve they were both told to use, which is exactly the drift the samples window exists to rule
/// out.
func spring(_ curve: MotionChoice.Curve, keyPath: String, from: Any, to: Any) -> CASpringAnimation {
    let bounce: CGFloat
    switch curve {
    case .smooth: bounce = 0
    case .snappy: bounce = 0.15
    case .bouncy: bounce = 0.3
    }
    let animation = CASpringAnimation(perceptualDuration: CardMotion.figureDuration, bounce: bounce)
    animation.keyPath = keyPath
    animation.fromValue = from
    animation.toValue = to
    // Nothing sets `duration` here: the `perceptualDuration:bounce:` initializer already sets it
    // equal to `settlingDuration` (measured 2026-09-04 for all three bounce values this app uses;
    // an explicit assignment to the same value was here and was a no-op).
    return animation
}
