export const API     = 'https://fellowscript.com/api';
export const WS_BASE = API.replace('https://', 'wss://').replace('http://', 'ws://');

// Prefer current tab's sessionStorage; fall back to localStorage for cross-tab persistence.
export const user = (() => {
  const s = JSON.parse(sessionStorage.getItem('user') || 'null');
  if (s) return s;
  const l = JSON.parse(localStorage.getItem('fs_user') || 'null');
  if (l) { sessionStorage.setItem('user', JSON.stringify(l)); return l; }
  return null;
})();
