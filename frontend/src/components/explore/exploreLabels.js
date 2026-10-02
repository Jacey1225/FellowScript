// Slug -> label helpers over the /explorer/filters vocabulary.
export function labelFor(vocab, key, slug) {
  const hit = (vocab?.[key] || []).find((o) => o.slug === slug);
  return hit ? hit.label : slug;
}

export function placeLine(l) {
  return [l.city, l.region, l.country].filter(Boolean).join(', ');
}

export function initialsOf(title) {
  const words = String(title || '').trim().split(/\s+/).filter(Boolean);
  if (!words.length) return '?';
  return (words[0][0] + (words.length > 1 ? words[1][0] : '')).toUpperCase();
}

// Up to three chips for a card: denomination, meeting format + frequency, place.
export function cardChips(l, vocab) {
  const chips = [];
  if (l.denominations?.[0]) chips.push(labelFor(vocab, 'denominations', l.denominations[0]));
  const meet = [
    l.meeting_format && labelFor(vocab, 'meeting_formats', l.meeting_format),
    l.frequency && labelFor(vocab, 'frequencies', l.frequency),
  ].filter(Boolean).join(', ');
  if (meet) chips.push(meet);
  const place = [l.city, l.region].filter(Boolean).join(', ') || l.country;
  if (place) chips.push(place);
  return chips.slice(0, 3);
}
