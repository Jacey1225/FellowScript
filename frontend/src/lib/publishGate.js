// Task 20261003-web-reader-ios-parity (step 3). Pre-check for the group info
// "Publish to Explorer" row, mirroring iOS GroupPublishSection.openPublish:
// publishing is subscribers only, so when the usage payload already says this
// user may not publish, show the shared upgrade modal instead of opening the
// website. Only an explicit `allowed: false` blocks. Any fetch failure or
// unexpected shape fails OPEN (the server stays authoritative and the manage
// page shows the same prompt if it blocks).
import { API } from '../config.js';

export async function isPublishBlocked(userId) {
  if (!userId) return false;
  try {
    const res = await fetch(`${API}/subscriptions/user/${encodeURIComponent(userId)}/usage`);
    if (!res.ok) return false;
    const body = await res.json();
    return body?.paid_only?.explorer_publish?.allowed === false;
  } catch {
    return false;
  }
}
