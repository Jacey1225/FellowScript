// Task 20260930-creator-friend-codes. SubscriptionCard promo UI: hidden when the
// flag is off (validate probe 404), apply/remove, uniform error, group plans
// never carry a code, promo_code only sent once the server validated it,
// invalid_promo_code at checkout clears the discount, friend invite code UI.
// Run: cd frontend && npm test -- --run src/components/SubscriptionCard.promo.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import SubscriptionCard from './SubscriptionCard.jsx';

afterEach(() => cleanup());
const USER = 'user-1';
const res = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });

// Route-based fetch mock so the order of the component's loads doesn't matter.
function mockApi({ flag = true, validate = () => ({ valid: false }), checkout, friend } = {}) {
  const calls = [];
  global.fetch = vi.fn(async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, init });
    if (u.includes(`/subscriptions/user/${USER}/requests`)) return res(200, []);
    if (u.includes(`/subscriptions/user/${USER}`)) return res(404, {});
    if (u.includes('/friends/')) return res(200, []);
    if (u.includes('/promo/') && u.endsWith('/validate')) {
      if (!flag) return res(404, { detail: 'Not found' });
      return res(200, validate(JSON.parse(init.body)));
    }
    if (u.includes('/promo/') && u.endsWith('/friend-code')) {
      if (!flag) return res(404, {});
      return friend ? friend() : res(200, { code: 'FRIENDCODE', link: 'https://x.test/?code=FRIENDCODE', percent_off: 50 });
    }
    if (u.endsWith('/subscriptions/checkout')) return checkout ? checkout(JSON.parse(init.body)) : res(200, { url: 'https://stripe.test/s' });
    return res(404, {});
  });
  return calls;
}
const checkoutBodies = (calls) => calls.filter((c) => c.url.endsWith('/subscriptions/checkout')).map((c) => JSON.parse(c.init.body));


// Node 26 ships its own (file-less, unusable) global localStorage that shadows
// jsdom's; install a plain in-memory Storage so the tests are runtime-independent.
function installMemoryStorage() {
  const m = new Map();
  vi.stubGlobal('localStorage', {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)); },
    removeItem: (k) => { m.delete(k); },
    clear: () => { m.clear(); },
  });
}

beforeEach(() => {
  installMemoryStorage();
  localStorage.clear();
  delete window.location;
  window.location = { href: '', search: '', hash: '', pathname: '/' };
});

describe('flag off', () => {
  test('no promo field, no friend invite section, checkout body has no promo_code', async () => {
    const calls = mockApi({ flag: false });
    render(<SubscriptionCard userId={USER} />);
    const subscribe = await screen.findByRole('button', { name: 'Subscribe' });
    await waitFor(() => expect(calls.some((c) => c.url.endsWith('/validate'))).toBe(true));
    expect(screen.queryByLabelText('Promo or invite code')).toBeNull();
    expect(screen.queryByText('Invite a friend')).toBeNull();
    fireEvent.click(subscribe);
    await waitFor(() => expect(checkoutBodies(calls).length).toBe(1));
    expect(checkoutBodies(calls)[0]).toEqual({ user_id: USER, member_count: 1 });
  });
});

describe('flag on', () => {
  test('shows the field and the invite section; no trial wording', async () => {
    mockApi();
    render(<SubscriptionCard userId={USER} />);
    expect(await screen.findByLabelText('Promo or invite code')).toBeTruthy();
    expect(screen.getByText('Invite a friend')).toBeTruthy();
    expect(document.body.textContent).not.toMatch(/free trial|free month|1 month free|start free/i);
  });

  test('valid code: applied, shows % off, checkout sends the normalized code once', async () => {
    const calls = mockApi({ validate: (b) => (b.code === 'PODCAST' ? { valid: true, percent_off: 50 } : { valid: false }) });
    render(<SubscriptionCard userId={USER} />);
    const input = await screen.findByLabelText('Promo or invite code');
    fireEvent.change(input, { target: { value: ' podcast ' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    expect(await screen.findByText('PODCAST')).toBeTruthy();
    expect(screen.getByText(/50% off your first month/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Subscribe' }));
    await waitFor(() => expect(checkoutBodies(calls).length).toBe(1));
    expect(checkoutBodies(calls)[0]).toEqual({ user_id: USER, member_count: 1, promo_code: 'PODCAST' });
  });

  test('invalid code shows one uniform error and checkout carries no code', async () => {
    const calls = mockApi();
    render(<SubscriptionCard userId={USER} />);
    fireEvent.change(await screen.findByLabelText('Promo or invite code'), { target: { value: 'nope' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    expect((await screen.findByRole('alert')).textContent).toBe("That code can't be used.");
    fireEvent.click(screen.getByRole('button', { name: 'Subscribe' }));
    await waitFor(() => expect(checkoutBodies(calls).length).toBe(1));
    expect(checkoutBodies(calls)[0]).not.toHaveProperty('promo_code');
  });

  test('typing without Apply never sends a code (only server-validated codes ride along)', async () => {
    const calls = mockApi({ validate: () => ({ valid: true, percent_off: 50 }) });
    render(<SubscriptionCard userId={USER} />);
    fireEvent.change(await screen.findByLabelText('Promo or invite code'), { target: { value: 'typedonly' } });
    fireEvent.click(screen.getByRole('button', { name: 'Subscribe' }));
    await waitFor(() => expect(checkoutBodies(calls).length).toBe(1));
    expect(checkoutBodies(calls)[0]).not.toHaveProperty('promo_code');
  });

  test('rate limited (429) shows a wait message, still no discount', async () => {
    mockApi();
    render(<SubscriptionCard userId={USER} />);
    const input = await screen.findByLabelText('Promo or invite code');
    global.fetch.mockImplementationOnce(async () => res(429, {}));
    fireEvent.change(input, { target: { value: 'abc' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/Too many tries/);
  });

  test('Remove clears the applied code', async () => {
    const calls = mockApi({ validate: () => ({ valid: true, percent_off: 50 }) });
    render(<SubscriptionCard userId={USER} />);
    fireEvent.change(await screen.findByLabelText('Promo or invite code'), { target: { value: 'abc' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Remove' }));
    expect(await screen.findByLabelText('Promo or invite code')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Subscribe' }));
    await waitFor(() => expect(checkoutBodies(calls).length).toBe(1));
    expect(checkoutBodies(calls)[0]).not.toHaveProperty('promo_code');
  });

  test('server 400 invalid_promo_code at checkout drops the discount and says nothing was charged', async () => {
    mockApi({
      validate: () => ({ valid: true, percent_off: 50 }),
      checkout: () => res(400, { detail: { code: 'invalid_promo_code', message: "This code isn't valid." } }),
    });
    render(<SubscriptionCard userId={USER} />);
    fireEvent.change(await screen.findByLabelText('Promo or invite code'), { target: { value: 'abc' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    await screen.findByRole('button', { name: 'Remove' });
    fireEvent.click(screen.getByRole('button', { name: 'Subscribe' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/not charged/);
    expect(screen.queryByRole('button', { name: 'Remove' })).toBeNull();
    expect(window.location.href).toBe('');
  });

  test('pending ?code= carried from a shared link is prefilled and auto-applied when valid', async () => {
    localStorage.setItem('fs_pending_promo_code', JSON.stringify({ code: 'SHARED1', at: Date.now() }));
    mockApi({ validate: (b) => (b.code === 'SHARED1' ? { valid: true, percent_off: 50 } : { valid: false }) });
    render(<SubscriptionCard userId={USER} />);
    expect(await screen.findByText('SHARED1')).toBeTruthy();
    expect(screen.getByText(/50% off your first month/)).toBeTruthy();
  });

  test('group size > 1 hides the field and never sends a code', async () => {
    const calls = mockApi({ validate: () => ({ valid: true, percent_off: 50 }) });
    render(<SubscriptionCard userId={USER} />);
    fireEvent.change(await screen.findByLabelText('Promo or invite code'), { target: { value: 'abc' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    await screen.findByRole('button', { name: 'Remove' });
    const members = screen.getByRole('spinbutton');
    fireEvent.change(members, { target: { value: '3' } });
    fireEvent.blur(members);
    expect(await screen.findByText('Codes apply to single-member plans.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Subscribe' }));
    await waitFor(() => expect(checkoutBodies(calls).length).toBe(1));
    expect(checkoutBodies(calls)[0]).toEqual({ user_id: USER, member_count: 3 });
  });
});

describe('friend invite code', () => {
  test('on demand: nothing fetched until clicked, then code shown and copyable', async () => {
    const calls = mockApi();
    const writeText = vi.fn().mockResolvedValue();
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true });
    render(<SubscriptionCard userId={USER} />);
    const btn = await screen.findByRole('button', { name: 'Get my invite code' });
    expect(calls.some((c) => c.url.endsWith('/friend-code'))).toBe(false);
    fireEvent.click(btn);
    expect((await screen.findByTestId('friend-code')).textContent).toBe('FRIENDCODE');
    fireEvent.click(screen.getByRole('button', { name: /Copy code/ }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith('FRIENDCODE'));
    fireEvent.click(screen.getByRole('button', { name: /Copy link/ }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith('https://x.test/?code=FRIENDCODE'));
  });

  test('failure shows an error, no code', async () => {
    mockApi({ friend: () => res(500, {}) });
    render(<SubscriptionCard userId={USER} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Get my invite code' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/Couldn't get your invite code/);
    expect(screen.queryByTestId('friend-code')).toBeNull();
  });
});
