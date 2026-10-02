import React from 'react';
import { SITE_URL } from '../config.js';

// Task 20261001-explorer-listings step 10. "Publish to Explorer" section of
// the group info panel, mounted through the groupInfoSections.js registry at
// order 10. Owner only and only when the server reports the explorer_publish
// capability (fail closed). The listing itself is edited on the website, so
// this just opens the manage page for this group in a new tab/window.
export function publishUrl(groupId) {
  return `${SITE_URL}/#/explore/manage?group=${encodeURIComponent(groupId)}`;
}

export default function GroupPublishSection({ groupId }) {
  const open = () => { window.open(publishUrl(groupId), '_blank', 'noopener,noreferrer'); };
  return (
    <section aria-labelledby="group-publish-h">
      <h3 id="group-publish-h" className="group-info-label">Publish to Explorer</h3>
      <p className="group-info-helper">
        List this group on the FellowScript website so adults looking for a group can find it and ask to join.
        You approve every request.
      </p>
      <div className="group-info-rename-actions">
        <button type="button" className="group-info-pill" onClick={open}>
          Publish to Explorer<span className="group-info-sr"> (opens in a new tab)</span>
        </button>
      </div>
    </section>
  );
}
