// Task 20261030-user-profiles: client mirror of api/backend/interactions/
// profile_bio.py's counting rule (NFC, whitespace collapsed, trimmed). The
// server stays authoritative; this only drives the counter and Save gating.
import { BIO_MAX_LENGTH } from './profileApi.js';

export const BIO_WARN_REMAINING = 20;

export function normalizeBioDraft(text) {
  return String(text ?? '').normalize('NFC').replace(/\s+/g, ' ').trim();
}

// -> { length, remaining, over, tone: 'normal' | 'warn' | 'over', label }
export function bioCounter(text, max = BIO_MAX_LENGTH) {
  const length = normalizeBioDraft(text).length;
  const remaining = max - length;
  if (remaining < 0) return { length, remaining, over: -remaining, tone: 'over', label: `Over by ${-remaining}` };
  if (remaining <= BIO_WARN_REMAINING) return { length, remaining, over: 0, tone: 'warn', label: `${remaining} left` };
  return { length, remaining, over: 0, tone: 'normal', label: `${length}/${max}` };
}
