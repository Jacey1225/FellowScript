// Task 20261030-thread-share-notes-verses (web/desktop, same bundle). Helpers
// for sending a shared verse / note into a thread: which threads the picker
// offers and when a pending share may be sent. The wire format is unchanged:
// the thread_message frame carries the same minimal attachment as chat and the
// server rebuilds meta and text. Throw-not-fabricate: a failed list or a thread
// that did not open yields an error / drop, never a guessed destination.
import { listThreads } from './threadsApi.js';
import { SHARED_FEATURE } from './sharedObjects.js';

export const THREADS_FEATURE = 'threads';
export const SHARE_THREAD_CAP = 10;

// Both flags must be on (fail closed); old servers show no thread rows.
export function canShareToThreads(caps) {
  return !!caps && typeof caps.isEnabled === 'function'
    && caps.isEnabled(THREADS_FEATURE) === true && caps.isEnabled(SHARED_FEATURE) === true;
}

// Recent threads of one group: first page of the existing list (newest
// activity first), capped. Rejects on failure so the caller can show an error.
export async function loadShareThreads(userId, groupId) {
  const page = await listThreads(userId, groupId, null);
  return page.threads.slice(0, SHARE_THREAD_CAP);
}

export function shareThreadLabel(thread) {
  const t = (thread && (thread.title || thread.root_preview)) || '';
  return String(t).trim() || 'Thread';
}

// 'wait' | 'send' | 'drop' for a pending share:
// { contactId, attachment, thread|null, opened }. `opened` is set once the chat
// history request returned. Chat shares send once the contact is current; thread shares only after the chosen thread's first page
// finished loading (an earlier send would be replaced by the history load).
export function pendingShareStatus(p, { contact, threadView, threadLoad }) {
  if (!p) return 'wait';
  if (!contact || contact.id !== p.contactId) return 'wait';
  if (!p.opened) return 'wait';
  if (!p.thread) return 'send';
  if (!threadView || threadView.thread.id !== p.thread.id) return 'drop';
  if (threadLoad === 'idle') return 'send';
  return threadLoad === 'error' ? 'drop' : 'wait';
}
