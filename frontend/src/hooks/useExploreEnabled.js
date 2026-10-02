import { useEffect, useState } from 'react';
import { probeExploreConfig } from '../lib/explorerApi.js';

// Task 20261001-explorer-listings step 9. Runtime (never build-time) probe for
// the Explore link. Home is statically prerendered, so the initial state is
// always false and effects do not run during renderToStaticMarkup: the
// prerendered bytes are unchanged. One probe per page load, shared by every
// caller; a failed or non-true probe leaves the link hidden.
let probePromise = null;

export function resetExploreProbeForTests() { probePromise = null; }

export function useExploreEnabled() {
  const [enabled, setEnabled] = useState(false);
  useEffect(() => {
    let cancelled = false;
    if (!probePromise) probePromise = probeExploreConfig();
    probePromise.then((ok) => { if (!cancelled) setEnabled(ok === true); });
    return () => { cancelled = true; };
  }, []);
  return enabled;
}
