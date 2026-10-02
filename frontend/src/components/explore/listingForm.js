// Form-state helpers for the owner listing form. The server is the authority
// on every rule (vocabulary, lengths, text policy); this only shapes data.
export const MULTI_FIELDS = [
  ['denominations', 'denominations', 'Denomination'],
  ['goals', 'goals', 'Goals'],
  ['practices', 'practices', 'Practices'],
  ['hobbies', 'hobbies', 'Hobbies'],
  ['age_ranges', 'age_ranges', 'Age range'],
  ['life_stages', 'life_stages', 'Life stage'],
  ['languages', 'languages', 'Languages'],
];
export const SINGLE_FIELDS = [
  ['meeting_format', 'meeting_formats', 'Meeting format'],
  ['frequency', 'frequencies', 'How often you meet'],
  ['gender_makeup', 'gender_makeup', 'Who is in the group'],
];
const TEXT_FIELDS = ['title', 'summary', 'church_name', 'country', 'region', 'city'];

let blockSeq = 0;
export const newBlock = (text = '') => ({ id: `b${++blockSeq}`, text });

export function emptyForm(groupTitle = '') {
  const f = { title: groupTitle || '', free_tags: [], blocks: [] };
  TEXT_FIELDS.forEach((k) => { if (!(k in f)) f[k] = ''; });
  MULTI_FIELDS.forEach(([k]) => { f[k] = []; });
  SINGLE_FIELDS.forEach(([k]) => { f[k] = ''; });
  return f;
}

export function formFromListing(l, groupTitle = '') {
  const f = emptyForm(groupTitle);
  if (!l) return f;
  TEXT_FIELDS.forEach((k) => { f[k] = l[k] || ''; });
  MULTI_FIELDS.forEach(([k]) => { f[k] = Array.isArray(l[k]) ? [...l[k]] : []; });
  SINGLE_FIELDS.forEach(([k]) => { f[k] = l[k] || ''; });
  f.free_tags = Array.isArray(l.free_tags) ? [...l.free_tags] : [];
  f.blocks = (l.description_blocks || [])
    .filter((b) => b && b.type === 'text' && typeof b.text === 'string')
    .map((b) => newBlock(b.text));
  return f;
}

// Body for PUT: every field, empty optional values as null, empty paragraphs
// dropped. accepting_requests is deliberately never part of a plain save.
export function bodyFromForm(f) {
  const body = { title: f.title.trim() };
  ['summary', 'church_name', 'country', 'region', 'city'].forEach((k) => { body[k] = f[k].trim() || null; });
  MULTI_FIELDS.forEach(([k]) => { body[k] = f[k]; });
  SINGLE_FIELDS.forEach(([k]) => { body[k] = f[k] || null; });
  body.free_tags = f.free_tags;
  body.description_blocks = f.blocks
    .map((b) => b.text.trim())
    .filter(Boolean)
    .map((text) => ({ type: 'text', text }));
  return body;
}

// Stable string for dirty checks (block ids ignored).
export function formSignature(f) {
  return JSON.stringify(bodyFromForm(f));
}

export function countryLabel(code, locale) {
  try {
    const dn = new Intl.DisplayNames(locale ? [locale] : undefined, { type: 'region' });
    return dn.of(code) || code;
  } catch {
    return code;
  }
}
