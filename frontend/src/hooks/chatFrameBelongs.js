// Decides whether an inbound chat frame belongs to the open conversation.
// Fails closed: anything ambiguous is dropped from the open view (history
// reload / push still deliver it to its real conversation).
//   group view: frame.group_id must equal the group's id (case-insensitive)
//   DM view:    frame must carry no group_id AND come from that friend
export function frameBelongsToContact(data, cc) {
  if (!data || !cc) return false;
  const fg = String(data.group_id || '').toLowerCase();
  const cg = String(cc.group_id || (cc.type === 'group' ? cc.id : '') || '').toLowerCase();
  if (cg) return fg === cg;
  if (fg) return false;
  return !!cc.id && data.from_user === cc.id;
}
