import React, { useState } from 'react';
import JoinRequestsList from './JoinRequestsList.jsx';

// Task 20261001-explorer-join-requests step 7. "Join requests" section of the
// group info panel, registered in groupInfoSections.js at order 20. Owner only
// and only when the server reports join_requests (the registry's isVisible).
export default function GroupJoinRequestsSection({ userId, groupId }) {
  const [count, setCount] = useState(0);
  return (
    <section aria-labelledby="group-join-requests-h">
      <h3 id="group-join-requests-h" className="group-info-label">
        Join requests
        {count > 0 && <span className="jr-badge" aria-label={`${count} pending ${count === 1 ? 'request' : 'requests'}`}>{count}</span>}
      </h3>
      <JoinRequestsList userId={userId} groupId={groupId} onCount={setCount} />
    </section>
  );
}
