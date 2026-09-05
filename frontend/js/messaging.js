// Messaging sidebar: WebSocket, contacts list, chat view, friend/group management.

import { API, WS_BASE, user } from './config.js';
import { escHtml, compareTimestamps } from './utils.js';

const msgSidebar      = document.getElementById('msg-sidebar');
const msgToggle       = document.getElementById('msg-toggle');
const msgContacts     = document.getElementById('msg-contacts');
const msgChat         = document.getElementById('msg-chat');
const msgChatName     = document.getElementById('msg-chat-name');
const msgMessages     = document.getElementById('msg-messages');
const msgGroupInfo    = document.getElementById('msg-group-info');
const msgGroupMembers = document.getElementById('msg-group-members');
const msgInput        = document.getElementById('msg-input');
const msgSend         = document.getElementById('msg-send');
const msgBack         = document.getElementById('msg-back');
const addFriendBtn    = document.getElementById('msg-add-friend-btn');
const addFriendForm   = document.getElementById('msg-add-friend-form');
const addFriendInput  = document.getElementById('msg-add-friend-input');
const addFriendSubmit = document.getElementById('msg-add-friend-submit');
const newGroupBtn     = document.getElementById('msg-new-group-btn');
const groupForm       = document.getElementById('msg-group-form');
const groupTitleInput = document.getElementById('msg-group-title');
const memberListEl    = document.getElementById('msg-member-list');
const groupSubmit     = document.getElementById('msg-group-submit');
const groupCancel     = document.getElementById('msg-group-cancel');

export let  msgWs        = null;
export const friendCache = {};   // { uid: username } — shared with notes.js

// Task 20260905-profile-photo: friendCache above is a bare username string,
// shared with notes.js, so a photo URL rides alongside it in its own cache
// rather than changing that shape. memberCache is the same idea for a
// group's resolved members -- GroupsManager.fetch_group only ever returns a
// bare username list (no ids, no photos), so each member is instead
// resolved from the group's own `toUsers` id list via the same GET
// /user/{id} endpoint friend resolution already uses below.
const friendPhotoCache = {}; // { uid: photoUrl|null }
const memberCache      = {}; // { uid: { username, photoUrl } }

let friendsData    = [];
let groupsData     = {};
let currentContact = null;
let editingGroupId = null;

// Renders an avatar's inner HTML: the initials fallback always sits in the
// DOM, with the photo (if any) layered on top via CSS (`.avatar-photo` is
// absolutely positioned, see reader.css) -- a failed/expired image just
// removes itself on error, revealing the initials underneath rather than a
// broken-image icon (no surface regresses to a broken image or blank space).
function avatarHtml(name, photoUrl) {
  const initial = escHtml(((name || '?')[0] || '?').toUpperCase());
  if (!photoUrl) return initial;
  return `${initial}<img class="avatar-photo" src="${escHtml(photoUrl)}" alt="" onerror="this.remove()" />`;
}

// ── Init ────────────────────────────────────────────────────────────────────

export function initMessaging() {
  msgToggle.addEventListener('click', () => {
    const open = msgSidebar.classList.toggle('open');
    document.body.classList.toggle('msg-open', open);
    if (open && user) { loadContactList(); if (!msgWs || msgWs.readyState > 1) connectWS(); }
  });

  // Desktop "← Notes" back button
  document.getElementById('msg-back-to-notes-btn')?.addEventListener('click', () => {
    msgSidebar.classList.remove('open');
    document.body.classList.remove('msg-open');
  });

  // Msg sidebar resize
  const resizeHandle = document.getElementById('msg-resize-handle');
  const MIN_W = 200, MAX_W = 700;
  resizeHandle.addEventListener('mousedown', e => {
    e.preventDefault();
    resizeHandle.classList.add('dragging');
    document.body.style.userSelect = 'none';
    document.body.style.cursor     = 'ew-resize';
    const onMove = ev => {
      const newW = Math.min(MAX_W, Math.max(MIN_W, ev.clientX));
      msgSidebar.style.width = newW + 'px';
      document.documentElement.style.setProperty('--msg-sidebar-w', newW + 'px');
    };
    const onUp = () => {
      resizeHandle.classList.remove('dragging');
      document.body.style.userSelect = '';
      document.body.style.cursor     = '';
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  });

  if (!user) {
    document.getElementById('msg-signin').style.display = 'flex';
    msgContacts.style.display = 'none';
    return;
  }

  // Friend controls
  addFriendBtn.addEventListener('click', () => {
    const visible = addFriendForm.style.display !== 'none';
    addFriendForm.style.display = visible ? 'none' : 'flex';
    if (!visible) addFriendInput.focus();
  });
  addFriendSubmit.addEventListener('click', _submitAddFriend);
  addFriendInput.addEventListener('keydown', e => { if (e.key === 'Enter') _submitAddFriend(); });

  // Group controls
  newGroupBtn.addEventListener('click', () => {
    const visible = groupForm.style.display !== 'none' && !editingGroupId;
    if (visible) { _resetGroupForm(); return; }
    editingGroupId = null;
    groupSubmit.textContent = 'Create';
    _populateMemberList();
    groupForm.style.display = 'block';
    groupTitleInput.focus();
  });
  groupCancel.addEventListener('click', _resetGroupForm);
  groupSubmit.addEventListener('click', _submitGroup);
  groupTitleInput.addEventListener('keydown', e => { if (e.key === 'Enter') _submitGroup(); });

  // Chat controls
  msgChatName.addEventListener('click', () => {
    if (currentContact?.type !== 'group') return;
    msgGroupInfo.style.display = msgGroupInfo.style.display !== 'none' ? 'none' : 'block';
  });
  msgSend.addEventListener('click', _sendMsg);
  msgInput.addEventListener('keydown', e => { if (e.key === 'Enter') _sendMsg(); });
  msgBack.addEventListener('click', () => {
    currentContact = null;
    msgGroupInfo.style.display = 'none';
    msgChatName.classList.remove('clickable');
    msgChat.style.display     = 'none';
    msgContacts.style.display = 'flex';
  });
}

// ── WebSocket ────────────────────────────────────────────────────────────────

export function connectWS() {
  if (!user) return;
  msgWs = new WebSocket(`${WS_BASE}/message/ws/${user.user_id}`);
  msgWs.onmessage = e => {
    try {
      const data = JSON.parse(e.data);
      if (currentContact &&
          data.from_user !== user.user_id &&
          (data.group_id || '') === (currentContact.group_id || '')) {
        _appendBubble(data.text || JSON.stringify(data), false, data.timestamp, data.from_user || '');
      }
    } catch (err) { console.error('[messaging] WS onmessage: malformed frame', err); }
  };
  msgWs.onclose = () => {
    if (msgSidebar.classList.contains('open')) setTimeout(connectWS, 3000);
  };
}

// ── Contacts ─────────────────────────────────────────────────────────────────

export async function loadContactList() {
  if (!user) return;
  let freshUser = user;
  try {
    const res = await fetch(`${API}/user/${user.user_id}`);
    if (res.ok) freshUser = await res.json();
    else console.warn('[messaging] loadContactList: /user fetch failed', res.status);
  } catch (err) { console.error('[messaging] loadContactList: /user fetch error', err); }

  // Friends
  const friendsList = document.getElementById('msg-friends-list');
  const friends     = freshUser.friends || [];
  friendsData = [];

  if (friends.length === 0) {
    friendsList.innerHTML = '<p class="msg-empty">No friends yet.</p>';
  } else {
    const items = await Promise.all(friends.map(async fid => {
      if (!friendCache[fid]) {
        try {
          const r = await fetch(`${API}/user/${fid}`);
          if (r.ok) {
            const d = await r.json();
            friendCache[fid] = d.username;
            friendPhotoCache[fid] = d.profile_photo_url || null;
          }
          else console.warn('[messaging] friend name lookup failed', fid, r.status);
        } catch (err) { console.error('[messaging] friend name lookup error', fid, err); friendCache[fid] = fid.slice(0, 8); }
      }
      const name = friendCache[fid] || fid.slice(0, 8);
      friendsData.push({ id: fid, name });

      let preview = '';
      try {
        const mr = await fetch(`${API}/message/messages/${user.user_id}/?guest_user=${fid}`);
        if (mr.ok) {
          const md  = await mr.json();
          const all = [...(md.payload?.host_msgs || []), ...(md.payload?.other_msgs || [])];
          if (all.length) {
            all.sort(compareTimestamps);
            preview = all[all.length - 1].text || '';
          }
        } else {
          console.warn('[messaging] preview fetch failed', fid, mr.status);
        }
      } catch (err) { console.error('[messaging] preview fetch error', fid, err); }

      return _contactItem(name, 'friend', fid, [fid], preview, friendPhotoCache[fid] || null);
    }));
    friendsList.innerHTML = '';
    items.forEach(item => friendsList.appendChild(item));
  }

  // Groups
  const groupsList = document.getElementById('msg-groups-list');
  const groupIds   = Array.isArray(freshUser.groups) ? freshUser.groups : [];

  if (groupIds.length === 0) {
    groupsList.innerHTML = '<p class="msg-empty">No groups yet.</p>';
  } else {
    const items = await Promise.all(groupIds.map(async gid => {
      try {
        const r = await fetch(`${API}/groups/${user.user_id}/${gid}`);
        if (r.ok) {
          const data = await r.json();
          const g    = data.group || {};
          groupsData[gid] = { title: g.title || gid, users: g.users || [] };
          const allMsgs = [...(data.host_msgs || []), ...(data.other_msgs || [])];
          let preview = '';
          if (allMsgs.length) {
            allMsgs.sort(compareTimestamps);
            preview = allMsgs[allMsgs.length - 1].text || '';
          }
          return _contactItem(g.title || gid, 'group', gid, g.users || [], preview);
        }
        console.warn('[messaging] group fetch failed', gid, r.status);
      } catch (err) { console.error('[messaging] group fetch error', gid, err); }
      return _contactItem(gid.slice(0, 8), 'group', gid, []);
    }));
    groupsList.innerHTML = '';
    items.forEach(item => groupsList.appendChild(item));
  }
}

function _contactItem(name, type, id, toUsers, preview = '', photoUrl = null) {
  const div = document.createElement('div');
  div.className = 'msg-contact-item';
  div.innerHTML =
    `<div class="msg-avatar">${avatarHtml(name, photoUrl)}</div>` +
    `<div class="msg-contact-info">` +
      `<span class="msg-contact-name">${escHtml(name)}</span>` +
      (preview ? `<span class="msg-contact-preview">${escHtml(preview)}</span>` : '') +
    `</div>` +
    (type === 'group'  ? `<button class="msg-edit-group-btn" title="Edit group">✎</button>` : '') +
    `<button class="msg-remove-btn" title="${type === 'friend' ? 'Remove friend' : 'Leave group'}">✕</button>`;

  div.addEventListener('click', e => {
    if (!e.target.closest('.msg-remove-btn') && !e.target.closest('.msg-edit-group-btn'))
      _openChat(name, type, id, toUsers);
  });
  div.querySelector('.msg-edit-group-btn')?.addEventListener('click', e => {
    e.stopPropagation(); _openGroupEdit(id);
  });
  div.querySelector('.msg-remove-btn').addEventListener('click', e => {
    e.stopPropagation();
    type === 'friend' ? _removeFriend(id, div) : _leaveGroup(id, div);
  });
  return div;
}

// ── Friends ──────────────────────────────────────────────────────────────────

async function _submitAddFriend() {
  const username = addFriendInput.value.trim();
  if (!username || !user) return;
  try {
    const res = await fetch(
      `${API}/friends/${user.user_id}/request?friend_username=${encodeURIComponent(username)}`,
      { method: 'POST' }
    );
    if (res.ok || res.status === 204) {
      addFriendInput.value        = '';
      addFriendForm.style.display = 'none';
    } else if (res.status === 404) {
      addFriendInput.style.borderColor = 'rgba(220,80,80,0.6)';
      setTimeout(() => { addFriendInput.style.borderColor = ''; }, 1500);
    } else {
      // Any other failure (500, expired session...) previously vanished with
      // no signal at all -- distinguish it from the "not found" case above
      // with the same border-flash idiom, and log it.
      console.warn('[messaging] add-friend request failed', res.status);
      addFriendInput.style.borderColor = 'rgba(220,80,80,0.6)';
      setTimeout(() => { addFriendInput.style.borderColor = ''; }, 1500);
    }
  } catch (err) {
    console.error('[messaging] add-friend request error:', err);
    addFriendInput.style.borderColor = 'rgba(220,80,80,0.6)';
    setTimeout(() => { addFriendInput.style.borderColor = ''; }, 1500);
  }
}

async function _removeFriend(friendId, rowEl) {
  if (!user) return;
  try {
    const res = await fetch(
      `${API}/friends/${user.user_id}/${encodeURIComponent(friendId)}`,
      { method: 'DELETE' }
    );
    if (res.ok || res.status === 204) {
      rowEl.remove();
    } else {
      console.warn('[messaging] remove-friend failed', friendId, res.status);
      alert('Could not remove that friend. Please try again.');
    }
  } catch (err) {
    console.error('[messaging] remove-friend error:', friendId, err);
    alert('Could not remove that friend. Check your connection and try again.');
  }
}

// ── Groups ────────────────────────────────────────────────────────────────────

function _populateMemberList(checkedIds = []) {
  memberListEl.innerHTML = '';
  if (friendsData.length === 0) {
    memberListEl.innerHTML =
      '<span style="font-size:0.72rem;color:rgba(244,228,193,0.3)">Add friends first</span>';
    return;
  }
  friendsData.forEach(f => {
    const label = document.createElement('label');
    const cb    = document.createElement('input');
    cb.type    = 'checkbox';
    cb.value   = f.id;
    cb.checked = checkedIds.includes(f.id);
    label.appendChild(cb);
    label.append(' ' + f.name);
    memberListEl.appendChild(label);
  });
}

function _resetGroupForm() {
  editingGroupId          = null;
  groupTitleInput.value   = '';
  groupSubmit.textContent = 'Create';
  groupForm.style.display = 'none';
}

function _openGroupEdit(gid) {
  const g = groupsData[gid] || {};
  editingGroupId          = gid;
  groupSubmit.textContent = 'Update';
  groupTitleInput.value   = g.title || '';
  _populateMemberList((g.users || []).filter(uid => uid !== user.user_id));
  groupForm.style.display = 'block';
  groupTitleInput.focus();
}

async function _submitGroup() {
  const title = groupTitleInput.value.trim();
  if (!title || !user) return;
  const memberIds = Array.from(memberListEl.querySelectorAll('input:checked')).map(cb => cb.value);
  const allUsers  = [...new Set([user.user_id, ...memberIds])];

  if (editingGroupId) {
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${editingGroupId}`, {
        method:  'PUT',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ group_id: editingGroupId, title, users: allUsers }),
      });
      if (res.ok || res.status === 204) {
        groupsData[editingGroupId] = { title, users: allUsers };
        _resetGroupForm();
        loadContactList();
      } else {
        // Previously failed with only this code comment and no UI signal
        // (dependency-errors #7) -- the form stayed open with no indication
        // anything went wrong, so a failed update looked identical to one
        // still in progress.
        console.warn('[messaging] group update failed', editingGroupId, res.status);
        alert('Could not update that group. Please try again.');
      }
    } catch (err) {
      console.error('[messaging] group update error:', editingGroupId, err);
      alert('Could not update that group. Check your connection and try again.');
    }
  } else {
    const groupId = crypto.randomUUID();
    try {
      const res = await fetch(`${API}/groups/${user.user_id}`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ group_id: groupId, title, users: allUsers }),
      });
      if (res.ok || res.status === 201) {
        _resetGroupForm();
        loadContactList();
      } else {
        console.warn('[messaging] group create failed', groupId, res.status);
        alert('Could not create that group. Please try again.');
      }
    } catch (err) {
      console.error('[messaging] group create error:', groupId, err);
      alert('Could not create that group. Check your connection and try again.');
    }
  }
}

async function _leaveGroup(groupId, itemEl) {
  if (!user) return;
  try {
    const res = await fetch(`${API}/groups/${user.user_id}/${groupId}`, { method: 'DELETE' });
    if (res.ok || res.status === 204) {
      itemEl.remove();
      const groupsList = document.getElementById('msg-groups-list');
      if (!groupsList.querySelector('.msg-contact-item'))
        groupsList.innerHTML = '<p class="msg-empty">No groups yet.</p>';

      // Sync notes group selector
      const sel = document.getElementById('group-sel');
      if (sel) {
        sel.querySelector(`option[value="${groupId}"]`)?.remove();
        if (sel.value === groupId) {
          sel.value = '';
          sel.dispatchEvent(new Event('change'));
        }
      }
    } else {
      // Previously failed with only a code comment and no UI signal
      // (dependency-errors #7) -- the row stayed in the list with no
      // indication the leave didn't actually happen.
      console.warn('[messaging] leave-group failed', groupId, res.status);
      alert('Could not leave that group. Please try again.');
    }
  } catch (err) {
    console.error('[messaging] leave-group error:', groupId, err);
    alert('Could not leave that group. Check your connection and try again.');
  }
}

// ── Chat ──────────────────────────────────────────────────────────────────────

async function _openChat(name, type, id, toUsers) {
  currentContact = { type, id, name, toUsers, group_id: type === 'group' ? id : '' };
  msgChatName.textContent = name;
  msgMessages.innerHTML   = '';
  msgGroupInfo.style.display  = 'none';
  msgGroupMembers.innerHTML   = '';
  msgChatName.classList.toggle('clickable', type === 'group');
  msgContacts.style.display = 'none';
  msgChat.style.display     = 'flex';

  try {
    const res = type === 'friend'
      ? await fetch(`${API}/friends/${user.user_id}/${id}`)
      : await fetch(`${API}/groups/${user.user_id}/${id}`);

    if (res.ok) {
      const data = await res.json();

      if (type === 'group') {
        // fetch_group's own `data.members` is a bare list of usernames (no
        // ids, no photos) -- resolve the richer { user_id, username,
        // photoUrl } shape from `toUsers` (the group's full member-id list,
        // self already excluded by the caller) via the same GET /user/{id}
        // endpoint friend resolution uses, cached per id.
        const resolvedMembers = await Promise.all((toUsers || []).map(async uid => {
          if (uid === user.user_id) return null;
          if (memberCache[uid]) return { user_id: uid, ...memberCache[uid] };
          try {
            const r = await fetch(`${API}/user/${uid}`);
            if (r.ok) {
              const d = await r.json();
              const resolved = { username: d.username || uid.slice(0, 8), photoUrl: d.profile_photo_url || null };
              memberCache[uid] = resolved;
              return { user_id: uid, ...resolved };
            }
          } catch (err) { console.error('[messaging] group member resolve error', uid, err); }
          return { user_id: uid, username: uid.slice(0, 8), photoUrl: null };
        }));
        msgGroupMembers.innerHTML =
          `<div class="msg-group-member">
            <div class="msg-group-member-avatar">${avatarHtml(user.username || 'You', user.profile_photo_url)}</div>
            <span class="msg-group-member-name is-you">${escHtml(user.username || 'You')} (you)</span>
          </div>` +
          resolvedMembers.filter(Boolean).map(m => {
            const uname = m.username || '?';
            return `<div class="msg-group-member">
              <div class="msg-group-member-avatar">${avatarHtml(uname, m.photoUrl)}</div>
              <span class="msg-group-member-name">${escHtml(uname)}</span>
            </div>`;
          }).join('');
      }

      const all = [
        ...(data.host_msgs  || []).map(m => ({ ...m, mine: true  })),
        ...(data.other_msgs || []).map(m => ({ ...m, mine: false })),
      ].sort(compareTimestamps);
      all.forEach(m => _appendBubble(m.text, m.mine, m.timestamp, m.mine ? '' : (m.from_user || '')));
    } else {
      console.warn('[messaging] _openChat: fetch failed', id, res.status);
      msgMessages.innerHTML = '<p class="msg-empty">Could not load messages.</p>';
    }
  } catch (err) {
    console.error('[messaging] _openChat error:', id, err);
    msgMessages.innerHTML = '<p class="msg-empty">Could not load messages.</p>';
  }

  msgMessages.scrollTop = msgMessages.scrollHeight;
}

function _appendBubble(text, mine, timestamp, sender = '') {
  const div  = document.createElement('div');
  div.className = `msg-bubble ${mine ? 'sent' : 'received'}`;
  const time = timestamp
    ? new Date(timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    : '';
  div.innerHTML =
    (!mine && sender ? `<div class="msg-bubble-sender">${escHtml(sender)}</div>` : '') +
    escHtml(String(text)) +
    (time ? `<div class="msg-bubble-meta">${time}</div>` : '');
  msgMessages.appendChild(div);
  msgMessages.scrollTop = msgMessages.scrollHeight;
}

function _sendMsg() {
  if (!user || !currentContact || !msgWs || msgWs.readyState !== 1) return;
  const text = msgInput.value.trim();
  if (!text) return;
  const payload = {
    from_user: user.user_id,
    timestamp: new Date().toISOString(),
    to_users:  currentContact.toUsers,
    group_id:  currentContact.group_id,
    text,
  };
  msgWs.send(JSON.stringify(payload));
  _appendBubble(text, true, payload.timestamp);
  msgInput.value = '';
}
