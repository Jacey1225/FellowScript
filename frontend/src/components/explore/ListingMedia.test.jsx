import React from 'react';
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';
import { afterEach } from 'vitest';

vi.mock('../../lib/listingMediaApi.js', async () => {
  const actual = await vi.importActual('../../lib/listingMediaApi.js');
  return { ...actual, uploadListingImage: vi.fn(), applyGroupPhoto: vi.fn(), deleteListingMedia: vi.fn() };
});
vi.mock('../BannerCropper.jsx', () => ({
  default: ({ onConfirm }) => <button type="button" onClick={() => onConfirm(new File(['x'], 'b.jpg', { type: 'image/jpeg' }))}>crop-done</button>,
}));
import * as api from '../../lib/listingMediaApi.js';
import ListingForm from './ListingForm.jsx';
import ListingMedia from './ListingMedia.jsx';
import DescriptionBlocks from './DescriptionBlocks.jsx';
import ListingHero from './ListingHero.jsx';
import { emptyForm, formFromListing, bodyFromForm, newImageBlock, imageBlocksMissingAlt, unreferencedImageIds } from './listingForm.js';

const MO = { video_enabled: false, allowed_mime: ['image/jpeg', 'image/png', 'image/webp'], image_max_upload_bytes: 8e6, alt_max_length: 300, max_description_images: 6 };
const S3 = 'https://b.s3.us-east-1.amazonaws.com/listings/p/u.jpg?sig=1';
const pngFile = () => new File(['x'], 'p.png', { type: 'image/png' });

beforeEach(() => vi.clearAllMocks());
afterEach(cleanup);

const mk = (over = {}) => ({ userId: 'u1', groupId: 'g1', listing: { public_id: 'p', media: [] }, options: MO, onChange: vi.fn(), disabled: false, ...over });
const pick = (container, f) => fireEvent.change(container.querySelector('input[type=file]'), { target: { files: [f] } });

describe('ListingMedia', () => {
  test('before the first save the controls are disabled with a hint', () => {
    render(<ListingMedia media={mk({ listing: null })} />);
    expect(screen.getByText(/Save your draft first/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add photo' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Use current group photo' })).toBeDisabled();
  });

  test('photo upload success calls onChange with the server item', async () => {
    const m = mk();
    api.uploadListingImage.mockResolvedValue({ media_id: 'm1', kind: 'photo', url: S3 });
    const { container } = render(<ListingMedia media={m} />);
    pick(container.querySelectorAll('.ex-uploader')[0], pngFile());
    fireEvent.click(screen.getByRole('button', { name: 'Upload' }));
    await waitFor(() => expect(m.onChange).toHaveBeenCalledWith({ kind: 'photo', item: expect.objectContaining({ media_id: 'm1' }) }));
    expect(api.uploadListingImage.mock.calls[0][0]).toMatchObject({ kind: 'photo', userId: 'u1', groupId: 'g1' });
  });

  test('rejects a wrong file type client-side without calling the API', () => {
    const { container } = render(<ListingMedia media={mk()} />);
    pick(container.querySelectorAll('.ex-uploader')[0], new File(['x'], 'a.gif', { type: 'image/gif' }));
    expect(screen.getByRole('alert')).toHaveTextContent(/JPEG, PNG or WebP/);
    expect(api.uploadListingImage).not.toHaveBeenCalled();
  });

  test('banner needs alt text before Upload is enabled', async () => {
    const { container } = render(<ListingMedia media={mk()} />);
    pick(container.querySelectorAll('.ex-uploader')[1], pngFile());
    fireEvent.click(screen.getByText('crop-done'));
    const up = await screen.findByRole('button', { name: 'Upload' });
    expect(up).toBeDisabled();
    fireEvent.change(screen.getByLabelText(/Describe this image/), { target: { value: 'Our room' } });
    expect(up).toBeEnabled();
  });

  test('upload error shows an alert and offers Try again', async () => {
    const { container } = render(<ListingMedia media={mk()} />);
    api.uploadListingImage.mockRejectedValue(Object.assign(new Error('The upload was refused.'), { status: 403 }));
    pick(container.querySelectorAll('.ex-uploader')[0], pngFile());
    fireEvent.click(screen.getByRole('button', { name: 'Upload' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('The upload was refused.');
    expect(screen.getByRole('button', { name: 'Try again' })).toBeEnabled();
  });

  test('retry after a confirm failure resumes with the S3 object key', async () => {
    const { container } = render(<ListingMedia media={mk()} />);
    api.uploadListingImage.mockImplementationOnce(async ({ onUploaded }) => { onUploaded('listings/p/u.png'); throw new Error('Processing failed'); });
    pick(container.querySelectorAll('.ex-uploader')[0], pngFile());
    fireEvent.click(screen.getByRole('button', { name: 'Upload' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Retry' }));
    await waitFor(() => expect(api.uploadListingImage).toHaveBeenCalledTimes(2));
    expect(api.uploadListingImage.mock.calls[1][0].resume).toEqual({ objectKey: 'listings/p/u.png' });
  });

  test('use current group photo and remove', async () => {
    const m = mk({ listing: { public_id: 'p', media: [{ media_id: 'm9', kind: 'photo', url: S3, alt_text: null }] } });
    api.applyGroupPhoto.mockResolvedValue({ media_id: 'm10', kind: 'photo', url: S3 });
    api.deleteListingMedia.mockResolvedValue({});
    render(<ListingMedia media={m} />);
    fireEvent.click(screen.getByRole('button', { name: 'Use current group photo' }));
    await waitFor(() => expect(m.onChange).toHaveBeenCalledWith({ kind: 'photo', item: expect.objectContaining({ media_id: 'm10' }) }));
    fireEvent.click(screen.getByRole('button', { name: 'Remove photo' }));
    await waitFor(() => expect(m.onChange).toHaveBeenCalledWith({ kind: 'photo', removed: 'm9' }));
    expect(api.deleteListingMedia).toHaveBeenCalledWith('u1', 'g1', 'm9');
  });

  test('a preview with an unsafe URL renders no img', () => {
    const m = mk({ listing: { public_id: 'p', media: [{ media_id: 'm9', kind: 'photo', url: 'javascript:alert(1)', alt_text: null }] } });
    const { container } = render(<ListingMedia media={m} />);
    expect(container.querySelector('img')).toBeNull();
  });
});

describe('ListingForm media', () => {
  const options = { vocab: {}, limits: {}, countries: [] };
  test('flag-off / no media prop hides all media UI', () => {
    render(<ListingForm form={emptyForm('G')} onChange={() => {}} options={options} media={null} />);
    expect(screen.queryByText('Photo and banner')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Add an image' })).toBeNull();
  });

  test('image block shows required alt error and body keeps alt', () => {
    const f = { ...emptyForm('G'), blocks: [newImageBlock('11111111-1111-1111-1111-111111111111', '')] };
    render(<ListingForm form={f} onChange={() => {}} options={options}
      media={{ ...mk(), listing: { public_id: 'p', media: [{ media_id: '11111111-1111-1111-1111-111111111111', kind: 'image', url: S3 }] } }} />);
    expect(screen.getByText(/Add a description before you save/)).toBeInTheDocument();
    expect(imageBlocksMissingAlt(f)).toHaveLength(1);
    expect(bodyFromForm({ ...f, blocks: [{ ...f.blocks[0], alt: ' Hi ' }] }).description_blocks).toEqual([
      { type: 'image', media_id: '11111111-1111-1111-1111-111111111111', alt: 'Hi' },
    ]);
  });

  test('add an image appends a block via the latest form', async () => {
    const onChange = vi.fn();
    api.uploadListingImage.mockResolvedValue({ media_id: 'mm', kind: 'image', url: S3, alt_text: 'Chairs' });
    const m = mk();
    const { container } = render(<ListingForm form={emptyForm('G')} onChange={onChange} options={options} media={m} />);
    pick(container.querySelectorAll('.ex-uploader')[2], pngFile());
    fireEvent.change(screen.getByLabelText(/Describe this image/), { target: { value: 'Chairs' } });
    fireEvent.click(screen.getByRole('button', { name: 'Upload' }));
    await waitFor(() => expect(onChange).toHaveBeenCalled());
    expect(onChange.mock.calls[0][0].blocks[0]).toMatchObject({ type: 'image', media_id: 'mm', alt: 'Chairs' });
    expect(m.onChange).toHaveBeenCalledWith({ kind: 'image', item: expect.objectContaining({ media_id: 'mm' }) });
  });

  test('formFromListing keeps image blocks that have a media row and drops orphans', () => {
    const l = { description_blocks: [{ type: 'text', text: 'hi' }, { type: 'image', media_id: 'a', alt: 'A' }, { type: 'image', media_id: 'gone', alt: 'B' }, { type: 'video', provider: 'youtube' }],
      media: [{ media_id: 'a', kind: 'image' }, { media_id: 'z', kind: 'image' }] };
    const f = formFromListing(l, 'G');
    expect(f.blocks.map((b) => b.type)).toEqual(['text', 'image']);
    expect(unreferencedImageIds(l.media, f.blocks)).toEqual(['z']);
  });
});

describe('DescriptionBlocks and ListingHero rendering', () => {
  test('renders a first-party image with alt, lazy, no-referrer', () => {
    const { container } = render(<DescriptionBlocks blocks={[{ type: 'image', url: S3, alt: 'Our room', width: 10, height: 5 }]} />);
    const img = container.querySelector('img');
    expect(img).toHaveAttribute('alt', 'Our room');
    expect(img).toHaveAttribute('loading', 'lazy');
    expect(img).toHaveAttribute('referrerpolicy', 'no-referrer');
  });

  test('malicious url or markup renders nothing', () => {
    const { container } = render(<DescriptionBlocks blocks={[
      { type: 'image', url: 'javascript:alert(1)', alt: 'x' },
      { type: 'image', url: 'https://evil.example.com/a.png', alt: 'x' },
      { type: 'image', url: '"><script>alert(1)</script>', alt: '<b>x</b>' },
      { type: 'html', html: '<img src=x onerror=alert(1)>' },
      { type: 'video', provider: 'evil', video_id: 'abc' },
      { type: 'video', provider: 'youtube', video_id: '"><script>' },
    ]} />);
    expect(container.querySelector('img, iframe, script')).toBeNull();
  });

  test('image alt that contains markup stays text, not markup', () => {
    const { container } = render(<DescriptionBlocks blocks={[{ type: 'image', url: S3, alt: '<script>x</script>' }]} />);
    expect(container.querySelector('script')).toBeNull();
    expect(container.querySelector('img')).toHaveAttribute('alt', '<script>x</script>');
  });

  test('server-sent video renders a sandboxed nocookie iframe; none when not sent', () => {
    const { container } = render(<DescriptionBlocks blocks={[{ type: 'video', provider: 'youtube', video_id: 'dQw4w9WgXcQ', title: 'Hi' }]} />);
    const f = container.querySelector('iframe');
    expect(f.getAttribute('src')).toBe('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ');
    expect(f.getAttribute('sandbox')).toBeTruthy();
    cleanup();
    expect(render(<DescriptionBlocks blocks={[]} />).container.querySelector('iframe')).toBeNull();
  });

  test('hero uses banner/photo only when first-party https', () => {
    const ok = render(<ListingHero listing={{ title: 'Grace', banner_url: S3, banner_alt: 'Hall', photo_url: S3 }} />);
    expect(ok.container.querySelectorAll('img')).toHaveLength(2);
    expect(ok.container.querySelector('.ex-hero-img')).toHaveAttribute('alt', 'Hall');
    cleanup();
    const bad = render(<ListingHero listing={{ title: 'Grace', banner_url: 'http://x.test/a.png', photo_url: 'javascript:1' }} />);
    expect(bad.container.querySelector('img')).toBeNull();
    expect(bad.container.textContent).toContain('G');
  });
});
