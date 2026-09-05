// Regression test for task 20260904-compliance-error-handling-consistency
// (dependency-errors #7): the legacy vanilla-JS messaging sidebar's group
// create/update/leave actions previously failed with only a code comment
// and zero UI signal -- a failed group create left the form open with no
// indication anything went wrong, indistinguishable from one still in
// progress. This now calls window.alert() with a specific message on
// failure, matching the same standard already applied elsewhere in this
// file (add-friend, remove-friend, openChat).
//
// Exercises the real _submitGroup() handler (module-private, reached only
// via the wired-up DOM event listener from initMessaging(), same approach
// notes.js's own legacy-tree test harness uses) for the group-CREATE path.
// The group-UPDATE and leave-group paths share the identical shape (same
// try/catch, same alert-on-non-ok / alert-on-throw structure -- see the
// diff) but aren't independently exercised here: reaching them requires
// simulating a rendered existing-group row (_openGroupEdit / the group
// "leave" contact-item click), which needs considerably more contact-list
// DOM setup than this file's create path. Flagged explicitly rather than
// silently omitted -- verified by direct code review instead (see this
// task's testing-gate summary).
//
// Run with: cd frontend && npm test -- --run js/messaging.group-error-signal.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';

const USER = { user_id: 'user-1', username: 'tester' };

// messaging.js reads these ids at module scope; notes.js (which re-exports/
// imports messaging.js indirectly in the real app shell) also needs its own
// ids satisfied for a clean import in this jsdom environment.
const REQUIRED_IDS = [
  'msg-sidebar', 'msg-toggle', 'msg-contacts', 'msg-chat', 'msg-chat-name',
  'msg-messages', 'msg-group-info', 'msg-group-members', 'msg-input',
  'msg-send', 'msg-back', 'msg-add-friend-btn', 'msg-add-friend-form',
  'msg-add-friend-input', 'msg-add-friend-submit', 'msg-new-group-btn',
  'msg-group-form', 'msg-group-title', 'msg-member-list', 'msg-group-submit',
  'msg-group-cancel', 'msg-groups-list', 'msg-friends-list',
  'msg-back-to-notes-btn', 'msg-resize-handle',
];

function mountShell() {
  document.body.innerHTML = REQUIRED_IDS
    .map(id => `<div id="${id}"${id === 'msg-group-form' ? ' style="display:none"' : ''}></div>`)
    .join('');
}

async function importFreshMessagingModule() {
  vi.resetModules();
  mountShell();
  sessionStorage.setItem('user', JSON.stringify(USER));
  return await import('./messaging.js');
}

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(window, 'alert').mockImplementation(() => {});
  sessionStorage.clear();
  localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('messaging.js group creation — surfaces a visible alert on failure (dependency-errors #7)', () => {
  test('a non-ok response alerts "Could not create that group" instead of silently leaving the form open', async () => {
    const messaging = await importFreshMessagingModule();
    messaging.initMessaging();

    document.getElementById('msg-new-group-btn').click();
    document.getElementById('msg-group-title').value = 'Bible Study Crew';

    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await document.getElementById('msg-group-submit').click();
    // _submitGroup is async; flush the microtask queue.
    await new Promise(resolve => setTimeout(resolve, 0));

    expect(window.alert).toHaveBeenCalledWith(expect.stringContaining('Could not create that group'));
    // The form must stay open/populated -- a failed create is not silently
    // treated as done.
    expect(document.getElementById('msg-group-form').style.display).toBe('block');
  });

  test('a thrown/network-failure alerts a distinct "check your connection" message', async () => {
    const messaging = await importFreshMessagingModule();
    messaging.initMessaging();

    document.getElementById('msg-new-group-btn').click();
    document.getElementById('msg-group-title').value = 'Bible Study Crew';

    global.fetch.mockRejectedValueOnce(new Error('network down'));
    await document.getElementById('msg-group-submit').click();
    await new Promise(resolve => setTimeout(resolve, 0));

    expect(window.alert).toHaveBeenCalledWith(expect.stringContaining('Check your connection'));
  });

  test('a successful (201) create never alerts and resets/closes the form', async () => {
    const messaging = await importFreshMessagingModule();
    messaging.initMessaging();

    document.getElementById('msg-new-group-btn').click();
    document.getElementById('msg-group-title').value = 'Bible Study Crew';

    global.fetch
      .mockResolvedValueOnce({ ok: true, status: 201, json: async () => ({}) }) // group create
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => (freshUserJSON()) }); // loadContactList's /user refetch

    await document.getElementById('msg-group-submit').click();
    await new Promise(resolve => setTimeout(resolve, 0));

    expect(window.alert).not.toHaveBeenCalled();
    expect(document.getElementById('msg-group-form').style.display).toBe('none');
  });
});

function freshUserJSON() {
  return { ...USER, friends: [], groups: [] };
}
