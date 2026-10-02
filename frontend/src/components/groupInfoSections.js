// Task 20261002-shared-foundation step 8. Data registry for extra sections in
// GroupInfoPanel, rendered once between "Member limit" and "Members". Later
// tasks only append an entry here (and add their own section file); they never
// edit GroupInfoPanel.jsx again.
//
// Entry: { key, order, isVisible(ctx) -> bool, component }
// Reserved orders (shared-contract-v2): publish 10, join_requests 20, threads 30.
// ctx: { features, userId, groupId, info, isOwner }. component receives ctx too.
// An empty registry renders nothing.
import GroupPublishSection from './GroupPublishSection.jsx';
import GroupThreadsSection from './GroupThreadsSection.jsx';

export const GROUP_INFO_SECTIONS = [
  // Task 20261001-explorer-listings: owner-only, flag-gated (fails closed).
  { key: 'publish', order: 10, isVisible: (ctx) => !!ctx.isOwner && ctx.features?.explorer_publish === true, component: GroupPublishSection },
  // Task 20261001-message-threads: flag-gated (fails closed), order 30.
  { key: 'threads', order: 30, isVisible: (ctx) => ctx.features?.threads === true, component: GroupThreadsSection },
];

export function getVisibleGroupInfoSections(ctx, sections = GROUP_INFO_SECTIONS) {
  return [...sections]
    .sort((a, b) => a.order - b.order)
    .filter((s) => {
      try { return !!s.isVisible(ctx); } catch { return false; }
    });
}
