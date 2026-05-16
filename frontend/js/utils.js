export function escHtml(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

export function hexWithAlpha(hex, alpha) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

export function verseRefLabel(verses) {
  if (!verses || !verses[0] || verses[0].length === 0) return '';
  const [bs, cs, vs] = verses[0];
  const [be, ce, ve] = verses[1] || [];
  const start = `${bs} ${cs}:${vs}`;
  const end   = be ? ` – ${be} ${ce}:${ve}` : '';
  return start + end;
}
