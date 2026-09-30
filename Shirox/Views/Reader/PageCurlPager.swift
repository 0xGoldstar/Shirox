#if os(iOS)
import SwiftUI
import UIKit

/// The page curl's rules, apart from the view.
enum PageCurl {
    /// Right to left binds the page at the right edge, so it curls from the left as a manga turns.
    static func spineLocation(rightToLeft: Bool) -> UIPageViewController.SpineLocation {
        rightToLeft ? .max : .min
    }

    /// The page `offset` steps from `id` in reading order, if there is one.
    static func neighbor(of id: Int, offset: Int, in ids: [Int]) -> Int? {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return nil }
        return ids[index + offset]
    }

    /// Whether a horizontal swipe turns forward: leftwards with the spine on the left, rightwards
    /// with it on the right.
    static func isForward(velocityX: CGFloat, rightToLeft: Bool) -> Bool {
        rightToLeft ? velocityX > 0 : velocityX < 0
    }

    /// Whether there's a page to turn to from `id`, forward or back in reading order.
    static func canTurn(from id: Int?, forward: Bool, in ids: [Int]) -> Bool {
        guard let id else { return false }
        return neighbor(of: id, offset: forward ? 1 : -1, in: ids) != nil
    }

    /// Whether a pan may start a curl: only if there's a page whichever way it turns. The swipe's
    /// motion and distance say one thing, where the page was grabbed may say another — the half
    /// away from the spine turns forward — and UIKit picks the way itself. Judged by motion alone,
    /// a leftward swipe grabbed on the first page's left half passed, UIKit curled it back to no
    /// page, and threw "The number of view controllers provided (0) doesn't match the number
    /// required (1) for the requested transition". Mid-chapter every way has a page.
    static func canBeginCurl(from id: Int?, velocityX: CGFloat, translationX: CGFloat, locationX: CGFloat,
                             width: CGFloat, rightToLeft: Bool, in ids: [Int]) -> Bool {
        var ways = [rightToLeft ? locationX < width / 2 : locationX > width / 2]
        if velocityX != 0 { ways.append(isForward(velocityX: velocityX, rightToLeft: rightToLeft)) }
        if translationX != 0 { ways.append(isForward(velocityX: translationX, rightToLeft: rightToLeft)) }
        return ways.allSatisfy { canTurn(from: id, forward: $0, in: ids) }
    }
}

/// The paged reader with Apple Books' page curl — `UIPageViewController`'s own `.pageCurl`, which
/// tracks the finger and lights the paper.
///
/// Pages stay in reading order in both directions; right to left only moves the spine. A zoomed
/// page pans instead of turning, and taps belong to the page (they toggle the reader's controls),
/// never to the curl's edge-tap.
struct PageCurlPager<Page: View>: UIViewControllerRepresentable {
    /// Page ids in reading order.
    let pageIDs: [Int]
    @Binding var current: Int
    let rightToLeft: Bool
    /// A page, given the callback that reports its zoom.
    let page: (Int, @escaping (CGFloat) -> Void) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .pageCurl, navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: PageCurl.spineLocation(rightToLeft: rightToLeft).rawValue)])
        controller.isDoubleSided = false
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        context.coordinator.uikitDelegate = controller.gestureRecognizers.first?.delegate
        for recognizer in controller.gestureRecognizers {
            recognizer.delegate = context.coordinator
        }
        if let first = context.coordinator.host(for: current) {
            controller.setViewControllers([first], direction: .forward, animated: false)
            context.coordinator.displayed = current
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Hands off while a curl is under the finger. UIKit reports the incoming page as shown
        // from the moment the curl starts, so the reader re-rendering meanwhile (it does, as pages
        // warm and progress saves) looked like a jump and put the old page back mid-turn: the
        // page jumped, the finished turn landed on the wrong page, and UIKit could crash.
        guard !coordinator.isTurning else { return }
        // A jump from outside — the page slider, a chapter pick, a resume — turns straight there,
        // as does the first page once there is one to show.
        let shown = coordinator.displayed
        guard shown != current, let target = coordinator.host(for: current) else { return }
        let forward = shown.map { (pageIDs.firstIndex(of: current) ?? 0) > (pageIDs.firstIndex(of: $0) ?? 0) } ?? true
        controller.setViewControllers([target], direction: forward ? .forward : .reverse, animated: false)
        coordinator.displayed = current
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                             UIGestureRecognizerDelegate {
        var parent: PageCurlPager
        /// UIKit's own delegate for the curl's gestures — the page view controller, which checks
        /// the data source before a curl starts. Replacing it outright dropped that check, and a
        /// swipe back on the first page (or on past the last) asked UIKit to turn to no page:
        /// "The number of view controllers provided (0) doesn't match the number required (1)".
        weak var uikitDelegate: UIGestureRecognizerDelegate?
        /// Pages zoomed past 1×, whose pans move the page rather than turn it.
        private var zoomed: Set<Int> = []
        /// The page on screen by the pager's own account: the one it put there or last finished
        /// turning to. Not `viewControllers`, which names the incoming page all through a curl.
        var displayed: Int?
        /// A curl is under way, from UIKit's word that it's starting until its word that it's over.
        private(set) var isTurning = false

        init(parent: PageCurlPager) {
            self.parent = parent
        }

        func host(for id: Int) -> UIViewController? {
            guard parent.pageIDs.contains(id) else { return nil }
            let page = parent.page(id) { [weak self] scale in
                if scale > 1.01 { self?.zoomed.insert(id) } else { self?.zoomed.remove(id) }
            }
            let host = CurlPageHost(pageID: id, rootView: AnyView(page))
            host.view.backgroundColor = .black
            return host
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let id = (viewController as? CurlPageHost)?.pageID,
                  let previous = PageCurl.neighbor(of: id, offset: -1, in: parent.pageIDs) else { return nil }
            return host(for: previous)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let id = (viewController as? CurlPageHost)?.pageID,
                  let next = PageCurl.neighbor(of: id, offset: 1, in: parent.pageIDs) else { return nil }
            return host(for: next)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isTurning = true
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTurning = false
            guard completed, let id = (pageViewController.viewControllers?.first as? CurlPageHost)?.pageID else { return }
            displayed = id
            parent.current = id
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Taps toggle the reader's controls, never turn the page.
            if gestureRecognizer is UITapGestureRecognizer { return false }
            guard let shown = displayed, !zoomed.contains(shown) else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view {
                guard PageCurl.canBeginCurl(from: shown,
                                            velocityX: pan.velocity(in: view).x,
                                            translationX: pan.translation(in: view).x,
                                            locationX: pan.location(in: view).x,
                                            width: view.bounds.width,
                                            rightToLeft: parent.rightToLeft,
                                            in: parent.pageIDs) else { return false }
            }
            return uikitDelegate?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
        }

        /// The page's own zoom scroll view tracks pans too; at 1× it has nowhere to go, so the
        /// curl runs beside it.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let shown = displayed else { return false }
            return !zoomed.contains(shown)
        }
    }
}

/// One page of the curl, remembering which page it shows.
final class CurlPageHost: UIHostingController<AnyView> {
    let pageID: Int

    init(pageID: Int, rootView: AnyView) {
        self.pageID = pageID
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
