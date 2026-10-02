// Status and error copy for the owner manage page. Warm and plain; reason
// labels mirror api/backend/interactions/listing_reports.REASON_LABELS.
export const STATUS_COPY = {
  draft: { label: 'Draft', body: 'Only you can see this. Submit it for review when you are ready.' },
  pending_review: { label: 'In review', body: 'We review every listing before it appears, usually within 24 hours.' },
  published: { label: 'Live', body: 'Your group is listed on Explore.' },
  unpublished: { label: 'Unpublished', body: 'Your listing is not shown on Explore. You can submit it again any time.' },
  rejected: { label: 'Not approved', body: 'We could not approve this listing. Fix what is mentioned below and submit it again.' },
  hidden: { label: 'Hidden', body: 'This listing is hidden while we review it.' },
};

export const REASON_LABELS = {
  inappropriate: "The listing contains content that does not fit FellowScript's community guidelines.",
  not_adults_only: 'Explore lists groups for adults 18 and over, and this listing appeared to be aimed at people under 18.',
  misleading: 'The listing was unclear or misleading about the group.',
  spam: 'The listing looked like advertising or spam.',
  duplicate: 'A listing for this group already exists.',
  incomplete: 'The listing did not have enough information to be approved.',
  reported: 'Several members of the community reported the listing, so it is hidden while we review it.',
  other: 'The listing did not meet our guidelines.',
};

export function reasonLabel(code) {
  return REASON_LABELS[code] || REASON_LABELS.other;
}

// Turns a thrown ExplorerApiError into { message, field, kind }. kind drives
// follow-up behaviour: 'terms' (open the Updated Terms gate), 'off' (page not
// available), 'rate' (wait), 'error'.
export function describeOwnerError(err) {
  const status = err?.status;
  const code = err?.code;
  if (status === 403 && code === 'terms_reaccept_required') {
    return { kind: 'terms', message: 'Please accept our updated Terms of Service to continue.' };
  }
  if (status === 404) return { kind: 'off', message: "This isn't available." };
  if (status === 429) return { kind: 'rate', message: 'Too many tries. Wait a moment and try again.' };
  if (status === 0) return { kind: 'error', message: "Couldn't reach FellowScript. Check your connection and try again." };
  if (status === 401) return { kind: 'auth', message: 'Please sign in again.' };
  return { kind: 'error', message: err?.message || 'Something went wrong. Please try again.' };
}
