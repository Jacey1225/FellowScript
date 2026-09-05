// Deployment-specific value (Configuration Q2) -- read from the page's own
// <meta name="api-base"> tag (account.html/reader.html/signin.html) so this
// no-build surface has one env-injectable override point per deploy instead
// of a hand-duplicated literal; the string below is only the fallback for a
// page missing that tag, not a second canonical value (see also
// frontend/src/config.js, which sources the React app's copy from Vite's
// build-time VITE_API_URL).
export const API     = document.querySelector('meta[name="api-base"]')?.content
  || 'https://fellowscript.com/api';
export const WS_BASE = API.replace('https://', 'wss://').replace('http://', 'ws://');

// Prefer current tab's sessionStorage; fall back to localStorage for cross-tab persistence.
export const user = (() => {
  const s = JSON.parse(sessionStorage.getItem('user') || 'null');
  if (s) return s;
  const l = JSON.parse(localStorage.getItem('fs_user') || 'null');
  if (l) { sessionStorage.setItem('user', JSON.stringify(l)); return l; }
  return null;
})();
