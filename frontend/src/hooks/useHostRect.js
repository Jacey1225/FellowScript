import { useLayoutEffect, useState } from 'react';

// Tracks `hostRef`'s live viewport bounding rect while `active`, for a
// full-bleed overlay that's createPortal'd to document.body but must still
// visually sit exactly over its host panel (see
// .claude/pipeline/20260826-notes-filter-panel-blur-increase). Escaping to
// document.body is required because an ancestor that already establishes its
// own backdrop-filter (here, dockview's `.dv-groupview`) prevents a nested
// descendant/sibling-covering element's own backdrop-filter from blurring
// the intervening sibling content, regardless of the descendant's own blur
// radius -- confirmed live (computed styles + real fine-text screenshots,
// swept 10px-60px) rather than assumed from source. Once the overlay leaves
// `.dv-groupview`'s DOM subtree it also leaves its normal `position:
// absolute; inset: 0` anchor, so this hook supplies the `position: fixed`
// coordinates needed to keep covering exactly the same rectangle.
//
// A rAF loop (not just a ResizeObserver) drives the tracking, because
// dockview can translate a panel without resizing it -- e.g. a sibling
// group's own resize shifting this one's top/left within a split layout --
// which a ResizeObserver alone would miss. The initial measurement runs in
// useLayoutEffect (synchronously, before paint) so the overlay never flashes
// at the wrong position/size on first open; the rAF loop then keeps it
// synced through any subsequent resize/dock move while `active`.
export function useHostRect(active, hostRef) {
  const [rect, setRect] = useState(null);

  useLayoutEffect(() => {
    if (!active) { setRect(null); return undefined; }

    let frame;
    let last = null;

    const measure = () => {
      const el = hostRef.current;
      if (el) {
        const r = el.getBoundingClientRect();
        if (!last || last.top !== r.top || last.left !== r.left || last.width !== r.width || last.height !== r.height) {
          last = { top: r.top, left: r.left, width: r.width, height: r.height };
          setRect(last);
        }
      }
      frame = requestAnimationFrame(measure);
    };
    measure();

    return () => cancelAnimationFrame(frame);
  }, [active, hostRef]);

  return rect;
}
