export const API     = 'https://fellowscript.com/api';
export const WS_BASE = API.replace('https://', 'wss://').replace('http://', 'ws://');
export const user    = JSON.parse(sessionStorage.getItem('user') || 'null');
