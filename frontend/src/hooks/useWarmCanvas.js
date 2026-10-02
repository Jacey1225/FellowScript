import { useEffect } from 'react';

// Toggles `page-warm` on <body> while the page is mounted: the warm
// brown-and-gold canvas (matching the iOS app) with a transparent header
// that sits flush on it. Styles live in styles/global.css next to
// body.page-reader.
export function useWarmCanvas() {
  useEffect(() => {
    document.body.classList.add('page-warm');
    return () => document.body.classList.remove('page-warm');
  }, []);
}
