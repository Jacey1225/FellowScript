export function escHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export function hexWithAlpha(hex, alpha) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

export function verseRefLabel(verses) {
  try {
    const [[bS, cS, vS], [bE, cE, vE]] = verses;
    if (!bS) return '';
    return (bS === bE && cS === cE && vS === vE)
      ? `${bS} ${cS}:${vS}`
      : `${bS} ${cS}:${vS} – ${bE} ${cE}:${vE}`;
  } catch {
    return '';
  }
}

// Build HTML for a chapter string (verse spans, section heads)
export function buildChapterHTML(chStr) {
  let text = chStr.replace(/\[\d+\]/g, '');
  const parts = text.split('HEAD::');
  let html = '';
  parts.forEach((part, idx) => {
    if (!part.trim()) return;
    if (idx > 0) {
      const vIdx = Math.min(
        part.search(/\d+:\d/)                === -1 ? Infinity : part.search(/\d+:\d/),
        part.search(/(?<!\d)\d+(?=[A-Za-z])/) === -1 ? Infinity : part.search(/(?<!\d)\d+(?=[A-Za-z])/)
      );
      if (isFinite(vIdx) && vIdx > 0) {
        html += `<span class="section-head">${part.slice(0, vIdx).trim()}</span>`;
        html += versesToHTML(part.slice(vIdx));
      } else {
        html += `<span class="section-head">${part.trim()}</span>`;
      }
    } else {
      html += versesToHTML(part);
    }
  });
  return html;
}

function versesToHTML(text) {
  if (!text.trim()) return '';
  text = text.replace(/^\s*\d+:(\d+)\s*/, '[[V$1]]');
  text = text.replace(/(?<!\d)(\d+)(?=[A-Za-z])/g, '[[V$1]]');
  const tokens = text.split(/\[\[V(\d+)\]\]/);
  let html = '';
  if (tokens[0].trim()) html += tokens[0];
  for (let i = 1; i < tokens.length; i += 2) {
    const vNum  = tokens[i];
    const vText = tokens[i + 1] || '';
    html +=
      `<span class="verse-span" id="vs${vNum}">` +
      `<sup class="vnum" data-v="${vNum}">${vNum}</sup>` +
      ` ${vText}` +
      `</span>`;
  }
  return html;
}

export function extractVerseNums(chStr) {
  const text = chStr.replace(/\[\d+\]/g, '');
  const nums = new Set();
  const first = text.match(/^(\d+):(\d+)/);
  if (first) nums.add(parseInt(first[2]));
  const remaining = text.replace(/^\d+:\d+\s*/, '');
  const re = /(?<!\d)(\d+)(?=[A-Za-z])/g;
  let m;
  while ((m = re.exec(remaining)) !== null) {
    const n = parseInt(m[1]);
    if (n >= 1 && n <= 250) nums.add(n);
  }
  return [...nums].sort((a, b) => a - b);
}
