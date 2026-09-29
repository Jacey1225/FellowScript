// Task 20260929-announcement-banner-crop-list-style testing: BannerCropper
// interactions. resolveCropSource/cropToFile are mocked (jsdom has no canvas).
// Run: cd frontend && npx vitest run src/components/BannerCropper.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';

vi.mock('../lib/cropBanner.js', async () => {
  const actual = await vi.importActual('../lib/cropBanner.js');
  return { ...actual, resolveCropSource: vi.fn(), cropToFile: vi.fn() };
});
import * as crop from '../lib/cropBanner.js';
import BannerCropper from './BannerCropper.jsx';

const NAT = { w: 1000, h: 3000 }; // tall photo; jsdom frame width falls back to 300 -> frame 300x100

async function ready(props = {}) {
  crop.resolveCropSource.mockResolvedValue({ objectUrl: 'blob:x', name: 'pic.png' });
  const onConfirm = vi.fn(); const onCancel = vi.fn();
  const utils = render(<BannerCropper source={{ file: new File(['x'], 'pic.png') }} onConfirm={onConfirm} onCancel={onCancel} {...props} />);
  const img = await waitFor(() => { const i = utils.container.querySelector('img.banner-cropper-img'); if (!i) throw new Error('no img'); return i; });
  Object.defineProperty(img, 'naturalWidth', { configurable: true, value: NAT.w });
  Object.defineProperty(img, 'naturalHeight', { configurable: true, value: NAT.h });
  fireEvent.load(img);
  await waitFor(() => expect(screen.getByText('Done')).not.toBeDisabled());
  return { ...utils, img, onConfirm, onCancel, frame: screen.getByTestId('banner-crop-frame') };
}

beforeEach(() => { crop.resolveCropSource.mockReset(); crop.cropToFile.mockReset(); });
afterEach(cleanup);

describe('BannerCropper', () => {
  test('has fixed 3:1 frame and labelled, 44px-class controls; Done disabled until the image loads', async () => {
    let resolve;
    crop.resolveCropSource.mockReturnValue(new Promise(r => { resolve = r; }));
    render(<BannerCropper source={{ file: new File(['x'], 'p.png') }} onConfirm={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.getByText('Done')).toBeDisabled();
    expect(screen.getByRole('dialog', { name: 'Crop banner' })).toBeTruthy();
    expect(screen.getByTestId('banner-crop-frame').style.aspectRatio).toMatch(/^3( \/ 1)?$/);
    for (const n of ['Zoom in', 'Zoom out', 'Zoom']) expect(screen.getByLabelText(n)).toBeDisabled();
    resolve({ objectUrl: 'blob:y', name: 'p.png' });
  });

  test('initial state covers the frame centered (tall photo -> vertical centre, no empty edges)', async () => {
    const { img } = await ready();
    const scale = 300 / NAT.w;                 // width-bound
    expect(parseFloat(img.style.width)).toBeCloseTo(300);
    expect(parseFloat(img.style.height)).toBeCloseTo(NAT.h * scale);
    expect(parseFloat(img.style.left)).toBeCloseTo(0);
    expect(parseFloat(img.style.top)).toBeCloseTo((100 - NAT.h * scale) / 2);
    expect(screen.getByLabelText('Zoom').value).toBe('1');
  });

  test('drag pans but is clamped so the image still covers the frame', async () => {
    const { img, frame } = await ready();
    fireEvent.pointerDown(frame, { clientX: 0, clientY: 0, button: 0, pointerId: 1 });
    fireEvent.pointerMove(frame, { clientX: 0, clientY: 5000, pointerId: 1 });
    expect(parseFloat(img.style.top)).toBeCloseTo(0);          // top edge pinned
    fireEvent.pointerMove(frame, { clientX: 0, clientY: -9000, pointerId: 1 });
    expect(parseFloat(img.style.top)).toBeCloseTo(100 - NAT.h * 0.3); // bottom edge pinned
    fireEvent.pointerUp(frame, { pointerId: 1 });
    fireEvent.pointerMove(frame, { clientX: 0, clientY: 0 });
    expect(parseFloat(img.style.top)).toBeCloseTo(100 - NAT.h * 0.3); // no drag after release
  });

  test('zoom buttons and slider change zoom within [1, max]; Reset restores center', async () => {
    const { img } = await ready();
    fireEvent.click(screen.getByLabelText('Zoom in'));
    expect(parseFloat(screen.getByLabelText('Zoom').value)).toBeCloseTo(1.25);
    expect(parseFloat(img.style.width)).toBeCloseTo(375);
    fireEvent.change(screen.getByLabelText('Zoom'), { target: { value: '4' } });
    expect(parseFloat(img.style.width)).toBeCloseTo(1200);
    fireEvent.click(screen.getByLabelText('Zoom in'));
    expect(parseFloat(screen.getByLabelText('Zoom').value)).toBe(4);
    fireEvent.click(screen.getByText('Reset'));
    expect(screen.getByLabelText('Zoom').value).toBe('1');
    expect(parseFloat(img.style.width)).toBeCloseTo(300);
    expect(parseFloat(img.style.top)).toBeCloseTo((100 - 900) / 2);
    fireEvent.click(screen.getByLabelText('Zoom out'));
    expect(screen.getByLabelText('Zoom').value).toBe('1');
  });

  test('keyboard: arrows nudge (moving the image), +/- zoom, Home resets', async () => {
    const { img, frame } = await ready();
    const top0 = parseFloat(img.style.top);
    fireEvent.keyDown(frame, { key: 'ArrowUp' });
    expect(parseFloat(img.style.top)).toBeCloseTo(top0 + 8);
    fireEvent.keyDown(frame, { key: 'ArrowDown', shiftKey: true });
    expect(parseFloat(img.style.top)).toBeCloseTo(top0 + 8 - 32);
    fireEvent.keyDown(frame, { key: '+' });
    expect(parseFloat(screen.getByLabelText('Zoom').value)).toBeCloseTo(1.25);
    fireEvent.keyDown(frame, { key: 'Home' });
    expect(screen.getByLabelText('Zoom').value).toBe('1');
    expect(parseFloat(img.style.top)).toBeCloseTo(top0);
  });

  test('Done bakes the crop: cropToFile receives the current 3:1 source rect and onConfirm gets its File', async () => {
    const { onConfirm, img } = await ready();
    const out = new File(['j'], 'pic.jpg', { type: 'image/jpeg' });
    crop.cropToFile.mockResolvedValue(out);
    fireEvent.click(screen.getByText('Done'));
    await waitFor(() => expect(onConfirm).toHaveBeenCalledWith(out));
    const [srcEl, rect, name] = crop.cropToFile.mock.calls[0];
    expect(srcEl).toBe(img);
    expect(name).toBe('pic.png');
    expect(rect.sw / rect.sh).toBeCloseTo(3, 4);
    expect(rect.sw).toBeCloseTo(NAT.w);                // zoom 1, width-bound
    expect(rect.sy).toBeCloseTo((NAT.h - rect.sh) / 2); // centred
  });

  test('encode failure shows an alert and does NOT confirm (never uploads uncropped)', async () => {
    const { onConfirm } = await ready();
    crop.cropToFile.mockRejectedValue(new crop.BannerCropError("Couldn't save the crop. Try again.", 'encode'));
    fireEvent.click(screen.getByText('Done'));
    expect((await screen.findByRole('alert')).textContent).toContain("Couldn't save the crop");
    expect(onConfirm).not.toHaveBeenCalled();
  });

  test('Cancel and Escape call onCancel without confirming', async () => {
    const { onConfirm, onCancel } = await ready();
    fireEvent.click(screen.getByText('Cancel'));
    expect(onCancel).toHaveBeenCalledTimes(1);
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onCancel).toHaveBeenCalledTimes(2);
    expect(onConfirm).not.toHaveBeenCalled();
  });

  test('CORS/source failure shows the Replace photo message with Try again and no Done', async () => {
    crop.resolveCropSource.mockRejectedValue(new crop.BannerCropError("Can't re-crop this banner. Choose Replace photo instead.", 'cors'));
    const onConfirm = vi.fn();
    render(<BannerCropper source={{ url: 'https://cdn/x.jpg' }} onConfirm={onConfirm} onCancel={vi.fn()} />);
    expect((await screen.findByRole('alert')).textContent).toContain('Choose Replace photo instead');
    expect(screen.getByText('Done')).toBeDisabled();
    fireEvent.click(screen.getByText('Try again'));
    await waitFor(() => expect(crop.resolveCropSource).toHaveBeenCalledTimes(2));
    expect(onConfirm).not.toHaveBeenCalled();
  });

  test('undecodable image (img error) surfaces an error', async () => {
    crop.resolveCropSource.mockResolvedValue({ objectUrl: 'blob:bad', name: 'x.png' });
    const { container } = render(<BannerCropper source={{ file: new File(['x'], 'x.png') }} onConfirm={vi.fn()} onCancel={vi.fn()} />);
    const img = await waitFor(() => { const i = container.querySelector('img'); if (!i) throw new Error('x'); return i; });
    fireEvent.error(img);
    expect((await screen.findByRole('alert')).textContent).toMatch(/Couldn't read this photo/);
  });
});
