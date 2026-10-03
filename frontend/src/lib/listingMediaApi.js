// Task 20261002-explorer-listing-media step 4: client for the owner listing
// media routes in api/routes/explorer.py (upload-url, confirm, group-photo,
// DELETE media/{id}). Flow: ask for a presigned POST, send the file straight
// to S3 as multipart (progress via XHR), then confirm. The server re-encodes
// and validates everything; the precheck here only saves a round trip and
// never replaces those checks. Throws ExplorerApiError (or MediaUploadError for
// the S3 hop). Nothing is fabricated.
import { request, ExplorerApiError } from './explorerApi.js';

const base = (userId, groupId) =>
  `/explorer/${encodeURIComponent(userId)}/groups/${encodeURIComponent(groupId)}/listing/media`;
const json = (method, body) => ({
  method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
});

export class MediaUploadError extends ExplorerApiError {
  constructor(message, status = 0) {
    super(message, status);
    this.name = 'MediaUploadError';
  }
}

const mb = (bytes) => Math.round((bytes / 1024 / 1024) * 10) / 10;

// Returns an error message, or null when the file looks acceptable.
export function precheckImage(file, mediaOptions) {
  if (!file) return 'Choose an image first.';
  const allowed = mediaOptions?.allowed_mime || ['image/jpeg', 'image/png', 'image/webp'];
  if (!allowed.includes(file.type)) return 'Use a JPEG, PNG or WebP image.';
  const max = mediaOptions?.image_max_upload_bytes;
  if (max && file.size > max) return `That image is too large. The limit is ${mb(max)} MB.`;
  if (file.size === 0) return 'That file is empty.';
  return null;
}

export function requestUploadUrl(userId, groupId, kind, contentType) {
  return request(`${base(userId, groupId)}/upload-url`, json('POST', { kind, content_type: contentType }),
    "Couldn't start the upload. Please try again.");
}

// Direct multipart POST to S3. The file must be the last field.
export function postToS3({ url, fields }, file, onProgress) {
  return new Promise((resolve, reject) => {
    let xhr;
    try {
      xhr = new XMLHttpRequest();
      xhr.open('POST', url);
    } catch {
      reject(new MediaUploadError('Upload failed. Please try again.'));
      return;
    }
    xhr.upload?.addEventListener?.('progress', (e) => {
      if (e.lengthComputable && onProgress) onProgress(Math.round((e.loaded / e.total) * 100));
    });
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else reject(new MediaUploadError('The upload was refused. Check the file and try again.', xhr.status));
    };
    xhr.onerror = () => reject(new MediaUploadError("Couldn't reach storage. Check your connection and try again."));
    xhr.onabort = () => reject(new MediaUploadError('The upload was cancelled.'));
    const form = new FormData();
    Object.entries(fields || {}).forEach(([k, v]) => form.append(k, v));
    form.append('file', file);
    xhr.send(form);
  });
}

export function confirmUpload(userId, groupId, kind, objectKey, altText) {
  return request(`${base(userId, groupId)}/confirm`,
    json('POST', { kind, object_key: objectKey, alt_text: altText ?? null }),
    "Couldn't process that image. Please try again.");
}

export function applyGroupPhoto(userId, groupId) {
  return request(`${base(userId, groupId)}/group-photo`, { method: 'POST' },
    "Couldn't use the group photo. Please try again.");
}

export function deleteListingMedia(userId, groupId, mediaId) {
  return request(`${base(userId, groupId)}/${encodeURIComponent(mediaId)}`, { method: 'DELETE' },
    "Couldn't remove that image. Please try again.");
}

// Whole upload. `resume.objectKey` skips the S3 hop when only confirm failed
// (retry). onStage('uploading'|'processing'), onProgress(0-100),
// onUploaded(objectKey) fires after S3 accepted the file.
export async function uploadListingImage({
  userId, groupId, kind, file, altText, mediaOptions, resume, onStage, onProgress, onUploaded,
}) {
  const bad = precheckImage(file, mediaOptions);
  if (bad) throw new MediaUploadError(bad);
  let objectKey = resume?.objectKey || null;
  if (!objectKey) {
    onStage?.('uploading');
    const presign = await requestUploadUrl(userId, groupId, kind, file.type);
    await postToS3(presign, file, onProgress);
    objectKey = presign.object_key;
    onUploaded?.(objectKey);
  }
  onStage?.('processing');
  return confirmUpload(userId, groupId, kind, objectKey, altText);
}
