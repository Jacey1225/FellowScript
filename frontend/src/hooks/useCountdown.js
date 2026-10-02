import { useEffect, useState } from 'react';

// Counts whole seconds down from `seconds` (0 or falsy = idle). Used to hold a
// retry button until a 429 Retry-After window has passed.
export function useCountdown(seconds) {
  const [left, setLeft] = useState(0);
  useEffect(() => {
    setLeft(seconds || 0);
    if (!seconds) return undefined;
    const t = setInterval(() => setLeft((n) => (n <= 1 ? 0 : n - 1)), 1000);
    return () => clearInterval(t);
  }, [seconds]);
  return left;
}
