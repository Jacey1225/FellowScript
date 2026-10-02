// Copy guard for the "agent events" -> "scheduled devotions" rename
// (task 20260902 scheduled-devotions-rename). User-visible wording only:
// API routes/fields (agent_events, /agent, heartbeat) must stay unchanged.
import { describe, test, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { HOME_SEO_DESCRIPTION } from './seo/homeSeo.js';

const read = (p) => fs.readFileSync(path.resolve(__dirname, p), 'utf8');

describe('scheduled devotions wording', () => {
  const account = read('pages/Account.jsx');
  const sub = read('components/SubscriptionCard.jsx');
  const home = read('pages/Home.jsx');

  test('Account page uses the canonical labels', () => {
    expect(account).toContain('label="Scheduled devotions"');
    expect(account).toContain('New scheduled devotion');
    expect(account).toContain('even when the app is closed');
    expect(account).not.toContain('label="Agent events"');
    expect(account).not.toContain('Scheduled events trigger an agent');
    expect(account).not.toContain('No events yet');
  });

  test('public identifiers are unchanged', () => {
    expect(account).toContain('usage.resources?.agent_events');
    expect(account).toContain('/heartbeat');
  });

  test('subscription card and Home use the new term', () => {
    expect(sub).toContain('Scheduled devotions');
    expect(sub).not.toContain('1 AI event');
    expect(home).toContain('1 scheduled devotion');
    expect(home).toContain('Unlimited scheduled devotions');
    expect(home).not.toMatch(/AI check-in/i);
  });

  test('SEO description mentions scheduled devotions', () => {
    expect(HOME_SEO_DESCRIPTION).toMatch(/scheduled devotions/);
    expect(HOME_SEO_DESCRIPTION).not.toMatch(/AI check-ins/);
  });
});
