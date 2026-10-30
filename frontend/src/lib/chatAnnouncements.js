// Task 20261030-chat-announcements: pure helpers for announcement lines in a
// group chat timeline (system_kind 'announcement'). No fetches and no React
// here. A line carries the viewer's announcement card (history) or a
// viewer-neutral card (live frame); an unusable card means no line fields at
// all, so the row degrades to the plain message text (never a placeholder).
// The full announcement (RSVP, polls, can_edit) is always re-fetched on open.

export const CHAT_ANNOUNCEMENT_FEATURE = 'chat_announcements';
export const ANNOUNCEMENT_KIND = 'announcement';

export const OPEN_ERROR = "Couldn't open that announcement. Please try again.";
export const GONE_ERROR = 'That announcement is no longer available.';

const str = (v) => (typeof v === 'string' ? v : undefined);

// Wire card -> the fields the row needs, or null when id/title are missing.
export function parseCard(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const id = str(raw.id);
  const title = str(raw.title);
  if (!id || title === undefined) return null;
  return {
    id,
    title,
    description: str(raw.description) || '',
    banner_url: str(raw.banner_url) || null,
    creator_username: str(raw.creator_username) || null,
    title_color: str(raw.title_color) || null,
    title_font: str(raw.title_font) || null,
    bg_theme: str(raw.bg_theme) || null,
    location: str(raw.location) || null,
    publish_at: str(raw.publish_at) || null,
    edited: raw.edited === true,
  };
}

// History row / live frame -> message fields for an announcement line.
export function announcementFields(row) {
  if (!row || row.system_kind !== ANNOUNCEMENT_KIND) return {};
  const card = parseCard(row.announcement);
  return card ? { systemKind: ANNOUNCEMENT_KIND, announcement: card } : {};
}

export const isAnnouncementLine = (m) => !!m && m.systemKind === ANNOUNCEMENT_KIND && !!m.announcement;

// The poster's own server-made line arrives on their socket too; it has no
// optimistic echo, so it is kept (every other self-sent frame is dropped).
export const isOwnAnnouncementFrame = (data, userId) =>
  !!data && data.system_kind === ANNOUNCEMENT_KIND && !!userId && data.from_user === userId
  && !!parseCard(data.announcement);

// `announcement_updated` frame -> { announcementId, action } or null.
export function parseSync(frame) {
  if (!frame || frame.type !== 'announcement_updated') return null;
  const announcementId = str(frame.announcement_id);
  if (!announcementId || !['updated', 'deleted', 'restored'].includes(frame.action)) return null;
  return { announcementId, action: frame.action };
}

export function removeAnnouncementLines(messages, announcementId) {
  const next = messages.filter((m) => !(isAnnouncementLine(m) && m.announcement.id === announcementId));
  return next.length === messages.length ? messages : next;
}

// Announcement lines of a fresh history body (paged or legacy shape).
export function announcementLinesFromHistory(data, toMessage) {
  if (!data || typeof data !== 'object') return [];
  const rows = Array.isArray(data.messages)
    ? data.messages.map((r) => toMessage(r))
    : [
        ...(data.host_msgs || []).map((r) => toMessage(r, true)),
        ...(data.other_msgs || []).map((r) => toMessage(r, false)),
      ];
  return rows.filter(isAnnouncementLine);
}

// Edited cards replace the old ones in place; restored lines are inserted at
// their time position (`insert` = threadsApi.insertRestored). Rows the fresh
// window does not cover are left alone.
export function mergeAnnouncementLines(current, fetched, insert) {
  let out = current;
  for (const line of fetched) {
    const idx = out.findIndex((m) => m.id && m.id === line.id);
    if (idx === -1) {
      out = insert(out, line);
    } else if (JSON.stringify(out[idx].announcement) !== JSON.stringify(line.announcement)) {
      out = out.slice();
      out[idx] = { ...out[idx], announcement: line.announcement };
    }
  }
  return out;
}

export function openErrorMessage(err) {
  return err && err.status === 404 ? GONE_ERROR : OPEN_ERROR;
}

// Create body for a chat post: the same body the Announcements form builds,
// plus the opt-in the server needs to put it in the timeline.
export const chatPostBody = (body) => ({ ...body, post_to_chat: true });
