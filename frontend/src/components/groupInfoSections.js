// Task 20261002-shared-foundation step 8. Data registry for extra sections in
// GroupInfoPanel, rendered once between "Member limit" and "Members". Later
// tasks only append an entry here (and add their own section file); they never
// edit GroupInfoPanel.jsx again.
//
// Entry: { key, order, isVisible(ctx) -> bool, component }
// Reserved orders (shared-contract-v2): publish 10, join_requests 20, threads 30.
// ctx: { features, userId, groupId, info, isOwner }. component receives ctx too.
// An empty registry renders nothing.
export const GROUP_INFO_SECTIONS = [];

export function getVisibleGroupInfoSections(ctx, sections = GROUP_INFO_SECTIONS) {
  return [...sections]
    .sort((a, b) => a.order - b.order)
    .filter((s) => {
      try { return !!s.isVisible(ctx); } catch { return false; }
    });
}
