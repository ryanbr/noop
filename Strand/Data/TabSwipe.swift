import Foundation

// MARK: - Tab swipe on the iOS tab shell
//
// `RootTabView` switches tabs on a decisive horizontal flick. Its tags are literal (Today 0, Trends 1,
// Sleep 2, Coach 3, More 4) and stay literal when the Coach tab is switched off, so More keeps its
// identity and navigation path. Stepping the raw tag by one therefore selected tag 3 whenever Coach was
// off, which no tab claims, and a swipe from Sleep showed a blank tab. The step lives here, pure, so it
// walks the tabs that actually exist and can be tested on the macOS test host.

/// The tab a horizontal swipe on the iOS tab shell moves to.
enum TabSwipe {
    /// The tab tags the shell renders, in order.
    static func visibleTags(coachShown: Bool) -> [Int] {
        coachShown ? [0, 1, 2, 3, 4] : [0, 1, 2, 4]
    }

    /// The next visible tag in the swipe's direction, stopping at either end. A current tag that is not
    /// visible (its tab was just removed) recovers to the first tab rather than staying blank.
    static func target(from current: Int, forward: Bool, visible: [Int]) -> Int {
        guard !visible.isEmpty else { return current }
        guard let index = visible.firstIndex(of: current) else { return visible[0] }
        let next = forward ? min(visible.count - 1, index + 1) : max(0, index - 1)
        return visible[next]
    }
}
