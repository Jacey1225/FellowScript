import React from 'react';

// Reserved mount point for the join-request CTA (task JRQ). Intentionally
// empty in the browse task; JRQ replaces the body without editing the
// Explore pages. `listing` carries public_id and requestable.
export default function JoinCtaSlot({ listing }) { // eslint-disable-line no-unused-vars
  return <div className="ex-join-slot" data-slot="join-cta" />;
}
