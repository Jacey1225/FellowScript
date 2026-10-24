// Task 20261024-announcement-polls: poll voting card, poll builder in the form, request bodies.
// Run: cd frontend && npx vitest run src/components/AnnouncementPolls.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';

vi.mock('../hooks/useCapabilities.js', () => ({ useCapabilities: () => ({ isEnabled: (f) => f === 'announcement_polls' }) }));
vi.mock('../lib/announcementsApi.js', async () => {
  const actual = await vi.importActual('../lib/announcementsApi.js');
  return { ...actual, uploadAnnouncementBanner: vi.fn() };
});
import AnnouncementPoll from './AnnouncementPoll.jsx';
import GroupAnnouncementForm from './GroupAnnouncementForm.jsx';
import { pollError, pollBody, POLL_LIMITS } from '../lib/announcementStyle.js';

const poll = (over = {}) => ({
  question: 'Which night?', multiple: false, closes_at: null, closed: false, total_voters: 3,
  options: [
    { id: 'a', label: 'Tuesday', votes: 2, percent: 67 },
    { id: 'b', label: 'Friday', votes: 1, percent: 33 },
  ],
  my_votes: [], ...over,
});
const item = (p, over = {}) => ({ id: 'ann1', published: true, can_edit: false, poll: p, ...over });

afterEach(cleanup);

describe('AnnouncementPoll card', () => {
  test('shows the question, counts, percentages and the anonymity note', () => {
    render(<AnnouncementPoll item={item(poll())} actions={{ vote: vi.fn(), retract: vi.fn() }} />);
    expect(screen.getByText('Which night?')).toBeInTheDocument();
    expect(screen.getByRole('radio', { name: /Tuesday, 2 votes, 67%/ })).toBeInTheDocument();
    expect(screen.getByRole('radio', { name: /Friday, 1 vote, 33%/ })).toBeInTheDocument();
    expect(screen.getByText(/3 people have voted/)).toBeInTheDocument();
    expect(screen.getByText(/Votes are anonymous/)).toBeInTheDocument();
  });

  test('tapping an option votes and shows the server result', async () => {
    const updated = { poll: poll({ my_votes: ['b'], total_voters: 4, options: [
      { id: 'a', label: 'Tuesday', votes: 2, percent: 50 }, { id: 'b', label: 'Friday', votes: 2, percent: 50 }] }) };
    const vote = vi.fn().mockResolvedValue(updated);
    render(<AnnouncementPoll item={item(poll())} actions={{ vote, retract: vi.fn() }} />);
    fireEvent.click(screen.getByRole('radio', { name: /Friday/ }));
    await waitFor(() => expect(vote).toHaveBeenCalledWith(['b']));
    await waitFor(() => expect(screen.getByRole('radio', { name: /Friday, 2 votes, 50%, your choice/ })).toBeInTheDocument());
    expect(screen.getByText(/4 people have voted/)).toBeInTheDocument();
  });

  test('multiple choice sends the whole selection', async () => {
    const vote = vi.fn().mockResolvedValue({ poll: poll({ multiple: true, my_votes: ['a', 'b'] }) });
    render(<AnnouncementPoll item={item(poll({ multiple: true, my_votes: ['a'] }))} actions={{ vote, retract: vi.fn() }} />);
    fireEvent.click(screen.getByRole('checkbox', { name: /Friday/ }));
    await waitFor(() => expect(vote).toHaveBeenCalledWith(['a', 'b']));
  });

  test('un-picking the last choice retracts the vote', async () => {
    const retract = vi.fn().mockResolvedValue({ poll: poll({ multiple: true, my_votes: [] }) });
    render(<AnnouncementPoll item={item(poll({ multiple: true, my_votes: ['a'] }))} actions={{ vote: vi.fn(), retract }} />);
    fireEvent.click(screen.getByRole('checkbox', { name: /Tuesday/ }));
    await waitFor(() => expect(retract).toHaveBeenCalled());
  });

  test('a closed poll cannot be voted in and says so', () => {
    const vote = vi.fn();
    render(<AnnouncementPoll item={item(poll({ closed: true }))} actions={{ vote, retract: vi.fn() }} />);
    fireEvent.click(screen.getByRole('radio', { name: /Friday/ }));
    expect(vote).not.toHaveBeenCalled();
    expect(screen.getByText(/Poll closed/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Close poll' })).not.toBeInTheDocument();
  });

  test('a 409 from the server reads as "just closed"', async () => {
    const vote = vi.fn().mockRejectedValue(Object.assign(new Error('x'), { status: 409 }));
    render(<AnnouncementPoll item={item(poll())} actions={{ vote, retract: vi.fn() }} />);
    fireEvent.click(screen.getByRole('radio', { name: /Friday/ }));
    expect(await screen.findByRole('alert')).toHaveTextContent('This poll just closed.');
  });

  test('only editors see Close poll, and it calls close', async () => {
    const close = vi.fn().mockResolvedValue({ poll: poll({ closed: true }) });
    const { rerender } = render(<AnnouncementPoll item={item(poll())} actions={{ vote: vi.fn(), retract: vi.fn(), close }} />);
    expect(screen.queryByRole('button', { name: 'Close poll' })).not.toBeInTheDocument();
    rerender(<AnnouncementPoll item={item(poll(), { can_edit: true })} actions={{ vote: vi.fn(), retract: vi.fn(), close }} />);
    fireEvent.click(screen.getByRole('button', { name: 'Close poll' }));
    await waitFor(() => expect(close).toHaveBeenCalled());
    expect(await screen.findByText(/Poll closed/)).toBeInTheDocument();
  });

  test('renders nothing without a poll', () => {
    const { container } = render(<AnnouncementPoll item={{ id: 'x' }} actions={{}} />);
    expect(container).toBeEmptyDOMElement();
  });
});

describe('poll helpers', () => {
  test('pollError catches the obvious mistakes', () => {
    expect(pollError({ question: '', options: ['a', 'b'] })).toMatch(/question/);
    expect(pollError({ question: 'q', options: ['a', ''] })).toMatch(/at least 2/);
    expect(pollError({ question: 'q', options: ['a', 'A'] })).toMatch(/different/);
    expect(pollError({ question: 'q', options: ['a', 'b'], closes: '2000-01-01T00:00' })).toMatch(/future/);
    expect(pollError({ question: 'q', options: ['a', 'b'] })).toBeNull();
    expect(POLL_LIMITS.maxOptions).toBe(6);
  });

  test('pollBody trims, drops blanks and converts the close time', () => {
    const b = pollBody({ question: '  Hi   there ', options: [' a ', '', 'b'], multiple: true, closes: '2999-01-01T10:00' });
    expect(b.question).toBe('Hi there');
    expect(b.options).toEqual(['a', 'b']);
    expect(b.multiple).toBe(true);
    expect(b.closes_at).toMatch(/^2999-01-01T/);
  });
});

describe('poll builder in the announcement form', () => {
  const mountForm = (props = {}) => {
    const onSubmit = vi.fn().mockResolvedValue(undefined);
    render(<GroupAnnouncementForm userId="u1" groupId="g1" item={null} gate={null} gateHit={false}
      upgrade={vi.fn()} onSubmit={onSubmit} onCancel={vi.fn()} {...props} />);
    return onSubmit;
  };
  // The extras live on the Style step of the 3-step form.
  const openExtras = () => {
    fireEvent.change(document.getElementById('announcement-title'), { target: { value: 'Study night' } });
    fireEvent.change(document.getElementById('announcement-description'), { target: { value: 'Join us' } });
    fireEvent.click(screen.getByRole('button', { name: /^Next/ }));
    fireEvent.click(screen.getByText(/Add extras/));
  };

  test('shows "Add a poll" in the extras and reveals the builder', () => {
    mountForm();
    openExtras();
    expect(screen.getByLabelText('Add a poll')).toBeInTheDocument();
    fireEvent.click(screen.getByLabelText('Add a poll'));
    expect(screen.getByLabelText('Question')).toBeInTheDocument();
    expect(screen.getByLabelText('Option 1')).toBeInTheDocument();
    expect(screen.getByLabelText('Option 2')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '+ Add option' }));
    expect(screen.getByLabelText('Option 3')).toBeInTheDocument();
    expect(screen.getByText(/Votes are anonymous/)).toBeInTheDocument();
  });

  test('options are capped at six and removable down to two', () => {
    mountForm();
    openExtras();
    fireEvent.click(screen.getByLabelText('Add a poll'));
    for (let i = 0; i < 6; i++) { const add = screen.queryByRole('button', { name: '+ Add option' }); if (add) fireEvent.click(add); }
    expect(screen.getByLabelText('Option 6')).toBeInTheDocument();
    expect(screen.queryByLabelText('Option 7')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '+ Add option' })).not.toBeInTheDocument();
    for (let i = 0; i < 6; i++) { const rm = screen.queryByRole('button', { name: 'Remove option 3' }); if (rm) fireEvent.click(rm); }
    expect(screen.queryByLabelText('Option 3')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Remove option/ })).not.toBeInTheDocument();
  });

  test('an incomplete poll shows an inline error', () => {
    mountForm();
    openExtras();
    fireEvent.click(screen.getByLabelText('Add a poll'));
    expect(screen.getAllByRole('alert').map((a) => a.textContent).join(' ')).toMatch(/question/);
    fireEvent.change(screen.getByLabelText('Question'), { target: { value: 'Which night?' } });
    expect(screen.getAllByRole('alert').map((a) => a.textContent).join(' ')).toMatch(/at least 2/);
  });

  test('locked options once people have voted', () => {
    mountForm({ item: { id: 'x', title: 't', description: 'd', published: true, poll: poll({ total_voters: 2 }) } });
    fireEvent.click(screen.getByRole('button', { name: /^Next/ }));
    expect(screen.getByLabelText('Option 1')).toBeDisabled();
    expect(screen.getByText(/options can't change/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '+ Add option' })).not.toBeInTheDocument();
  });
});
