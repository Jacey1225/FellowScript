// Deployment-specific value (Configuration Q2) -- sourced from Vite's
// build-time env (VITE_API_URL, see frontend/.env) rather than hand-kept in
// sync with frontend/js/config.js's own copy for the no-build legacy pages.
// The literal below is only the local-dev/no-.env fallback, not a second
// canonical value.
export const API     = import.meta.env.VITE_API_URL || 'https://fellowscript.com/api';
export const WS_BASE = API.replace('https://', 'wss://').replace('http://', 'ws://');
