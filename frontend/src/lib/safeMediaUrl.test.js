import { describe, test, expect } from 'vitest';
import { safeMediaUrl, isFirstPartyMediaUrl } from './safeMediaUrl.js';

describe('safeMediaUrl', () => {
  test('accepts https S3 virtual-host URLs', () => {
    const u = 'https://bucket.s3.us-east-1.amazonaws.com/listings/abc/x.jpg?X-Amz-Signature=1';
    expect(safeMediaUrl(u)).toBe(u);
  });
  test.each([
    'http://bucket.s3.amazonaws.com/x.jpg',
    'javascript:alert(1)',
    'data:image/png;base64,AAAA',
    'https://evil.example.com/x.jpg',
    'https://bucket.s3.amazonaws.com.evil.com/x.jpg',
    'https://user:pw@bucket.s3.amazonaws.com/x.jpg',
    '//bucket.s3.amazonaws.com/x.jpg',
    '<img src=x onerror=alert(1)>',
    '',
    null,
    undefined,
    42,
    {},
  ])('rejects %p', (v) => {
    expect(safeMediaUrl(v)).toBeNull();
    expect(isFirstPartyMediaUrl(v)).toBe(false);
  });
});
