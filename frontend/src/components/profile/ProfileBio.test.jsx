// Task 20261030-user-profiles testing step 8: bio display tiers.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import ProfileBio from './ProfileBio.jsx';

afterEach(cleanup);

describe('ProfileBio', () => {
  test('stranger (bio key absent): hidden-for-friends line, nothing else', () => {
    render(<ProfileBio profile={{ username: 'a', relationship: { state: 'none' } }} />);
    expect(screen.getByText('Bio is shared with friends.')).toBeInTheDocument();
  });

  test('friend with a bio shows it as text', () => {
    render(<ProfileBio profile={{ relationship: { state: 'friends' }, bio: 'Walking with Jesus' }} />);
    expect(screen.getByText('Walking with Jesus')).toBeInTheDocument();
  });

  test('friend with null bio: "No bio yet."', () => {
    render(<ProfileBio profile={{ relationship: { state: 'friends' }, bio: null }} />);
    expect(screen.getByText('No bio yet.')).toBeInTheDocument();
  });

  test('self without bio: Add bio button calls onEdit', () => {
    const onEdit = vi.fn();
    render(<ProfileBio profile={{ relationship: { state: 'self' }, editable: true, bio: null }} onEdit={onEdit} />);
    fireEvent.click(screen.getByRole('button', { name: /add bio/i }));
    expect(onEdit).toHaveBeenCalledTimes(1);
  });

  test('bio is rendered as plain text: markup and links are not interpreted', () => {
    const evil = '<img src=x onerror=alert(1)> https://evil.example';
    const { container } = render(<ProfileBio profile={{ relationship: { state: 'friends' }, bio: evil }} />);
    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('a')).toBeNull();
    expect(container.textContent).toBe(evil);
  });
});
