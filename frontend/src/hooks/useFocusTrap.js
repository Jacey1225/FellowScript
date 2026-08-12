import { useEffect, useRef } from 'react';

// Minimal focus trap for the mobile-only overlays/popovers introduced by
// Direction C (design-notes.md §4: "new overlays/Popovers trap focus while
// open and return focus to the trigger button on close"). While `active`,
// Tab/Shift+Tab cycles within `containerRef`'s focusable elements instead of
// escaping to the page behind it; when `active` flips back to false (or the
// consumer unmounts while still active), focus returns to whatever element
// had it before the trap activated -- normally the row/pill button that
// triggered the overlay/popover in the first place.
const FOCUSABLE_SELECTOR = 'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])';

export function useFocusTrap(active, containerRef) {
  const previouslyFocused = useRef(null);

  useEffect(() => {
    if (!active) return undefined;

    previouslyFocused.current = document.activeElement;

    const getFocusable = () => {
      const container = containerRef.current;
      if (!container) return [];
      return Array.from(container.querySelectorAll(FOCUSABLE_SELECTOR))
        .filter(el => !el.disabled && el.offsetParent !== null);
    };

    // Move focus inside the trap as soon as it activates.
    const focusables = getFocusable();
    if (focusables.length) focusables[0].focus();

    const onKeyDown = (e) => {
      if (e.key !== 'Tab') return;
      const items = getFocusable();
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    };

    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('keydown', onKeyDown);
      const toRestore = previouslyFocused.current;
      if (toRestore && typeof toRestore.focus === 'function' && document.contains(toRestore)) {
        toRestore.focus();
      }
    };
  }, [active, containerRef]);
}
