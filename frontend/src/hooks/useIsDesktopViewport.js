import { useState, useEffect } from 'react';

// Matches the CSS `@media (max-width: 1024px)` breakpoint in global.css that
// switches the Reader page between the desktop dockview workspace and the
// mobile bottom-tab-bar/fullscreen-overlay layout. Reactive (unlike a plain
// `window.innerWidth` check at render time) so resizing across the breakpoint
// actually mounts/unmounts the right branch instead of relying on CSS alone —
// required once desktop mounts a real DockviewReact instance, since leaving it
// mounted-but-hidden would duplicate panel side effects and confuse its
// ResizeObserver-driven sizing inside a zero-size container.
const QUERY = '(min-width: 1025px)';

export function useIsDesktopViewport() {
  const [isDesktop, setIsDesktop] = useState(() =>
    typeof window !== 'undefined' ? window.matchMedia(QUERY).matches : true
  );

  useEffect(() => {
    const mql = window.matchMedia(QUERY);
    const onChange = (e) => setIsDesktop(e.matches);
    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, []);

  return isDesktop;
}
