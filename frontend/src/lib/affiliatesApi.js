// Task 20261007-affiliates-page. Thin client for the creator Affiliates endpoints
// (api/routes/affiliates.py). Nothing here carries a creator or code id: the
// server derives the creator from the session cookie. Every function throws
// AffiliatesApiError (with `.status`) on any non-2xx or network failure
// (throw-not-fabricate). 404 = feature off, 401 = signed out, 403 = not a creator.
import { API } from '../config.js';

export class AffiliatesApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'AffiliatesApiError';
    this.status = status;
  }
}

const FILE_PREFIX = '/affiliates/resources/';

async function get(path, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, { credentials: 'include' });
  } catch {
    throw new AffiliatesApiError('Could not reach the server.', 0);
  }
  if (!res.ok) throw new AffiliatesApiError(fallback, res.status);
  return res;
}

export async function getAffiliateOverview() {
  const res = await get('/affiliates/overview', "Couldn't load your affiliate overview.");
  return res.json();
}

export async function getAffiliateResources() {
  const res = await get('/affiliates/resources', "Couldn't load promotion resources.");
  return res.json();
}

// `url` is the server-provided resource path from getAffiliateResources(). Only
// paths under /affiliates/resources/ are fetched. Resolves a Blob.
export async function fetchAffiliateFile(url) {
  if (typeof url !== 'string' || !url.startsWith(FILE_PREFIX) || url.includes('..') || url.includes('?')) {
    throw new AffiliatesApiError('Unavailable', 0);
  }
  const res = await get(url, 'Unavailable');
  return res.blob();
}
