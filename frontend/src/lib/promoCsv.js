// Admin promo-code CSV export. Pure helpers: build the CSV text and trigger the
// browser download. Cells starting with = + - @ (or tab/CR) are prefixed with a
// single quote so spreadsheet apps never evaluate them as formulas.
const COLUMNS = [
  ['code', 'Code'],
  ['kind', 'Kind'],
  ['creator_name', 'Creator name'],
  ['owner_email', 'Owner email'],
  ['active', 'Status'],
  ['redemption_count', 'Redemptions'],
  ['max_redemptions', 'Max redemptions'],
  ['rewards_earned', 'Rewards earned'],
  ['rewards_claimed', 'Rewards claimed'],
  ['expires_at', 'Expires at'],
  ['created_at', 'Created at'],
];

function cell(value) {
  if (value === null || value === undefined) return '';
  let s = String(value);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function codesToCsv(rows) {
  const header = COLUMNS.map(([, label]) => label).join(',');
  const lines = rows.map((r) => COLUMNS.map(([key]) => (
    key === 'active' ? cell(r.active ? 'Active' : 'Inactive') : cell(r[key])
  )).join(','));
  return `${[header, ...lines].join('\r\n')}\r\n`;
}

export function csvFilename(kind, now = new Date()) {
  const day = now.toISOString().slice(0, 10);
  return `fellowscript-${kind || 'all'}-codes-${day}.csv`;
}

export function downloadCsv(text, filename) {
  const url = URL.createObjectURL(new Blob([`﻿${text}`], { type: 'text/csv;charset=utf-8' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}
