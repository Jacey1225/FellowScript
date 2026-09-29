import React, { useRef } from 'react';
import { CheckOutlined, PlusOutlined } from '@ant-design/icons';
import {
  TITLE_COLOR_SWATCHES, TITLE_COLOR_DEFAULT, normalizeHex, isDefaultColor, luminance, colorName, needsLegibilityWarning,
} from '../lib/announcementTitleColor.js';

// Swatch row + custom picker for the announcement title color. `value` is null
// (default) or a strict #RRGGBB; onChange receives null or an uppercase hex.
export default function TitleColorPicker({ value, onChange, disabled }) {
  const current = normalizeHex(value) || TITLE_COLOR_DEFAULT;
  const isCustom = !TITLE_COLOR_SWATCHES.some((s) => s.hex === current);
  const refs = useRef([]);
  const checkColor = (hex) => ((luminance(hex) ?? 1) > 0.4 ? '#000' : '#fff');
  const pick = (hex) => onChange(hex === TITLE_COLOR_DEFAULT ? null : hex);

  const onKeyDown = (e, i) => {
    const n = TITLE_COLOR_SWATCHES.length;
    let next = null;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = (i + 1) % n;
    if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = (i - 1 + n) % n;
    if (next == null) return;
    e.preventDefault();
    refs.current[next]?.focus();
    pick(TITLE_COLOR_SWATCHES[next].hex);
  };

  return (
    <div className="title-color-picker">
      <div className="title-color-swatches" role="radiogroup" aria-label="Title color">
        {TITLE_COLOR_SWATCHES.map((s, i) => {
          const selected = !isCustom && current === s.hex;
          return (
            <button key={s.hex} type="button" role="radio" aria-checked={selected} aria-label={s.name} title={s.name}
              ref={(el) => { refs.current[i] = el; }} disabled={disabled}
              tabIndex={selected || (isCustom && i === 0) ? 0 : -1}
              className={`title-color-swatch${selected ? ' title-color-swatch-on' : ''}`}
              onKeyDown={(e) => onKeyDown(e, i)} onClick={() => pick(s.hex)}>
              <span className="title-color-dot" style={{ backgroundColor: s.hex }}>
                {selected && <CheckOutlined style={{ color: checkColor(s.hex) }} />}
              </span>
            </button>
          );
        })}
        <label className={`title-color-swatch title-color-custom${isCustom ? ' title-color-swatch-on' : ''}`}
          title="Custom color">
          <span className="title-color-dot" style={isCustom ? { backgroundColor: current } : undefined}>
            {isCustom ? <CheckOutlined style={{ color: checkColor(current) }} /> : <PlusOutlined />}
          </span>
          <input type="color" className="title-color-input" disabled={disabled}
            aria-label={isCustom ? `Custom color ${current}` : 'Custom color'} value={current.toLowerCase()}
            onChange={(e) => { const n = normalizeHex(e.target.value); if (n) pick(n); }} />
        </label>
      </div>
      <p className="group-info-helper">Title color: {colorName(value)}</p>
      {!isDefaultColor(value) && (
        <button type="button" className="group-info-text-btn" disabled={disabled} onClick={() => onChange(null)}>Reset to default</button>
      )}
      {needsLegibilityWarning(value) && (
        <p className="group-info-helper title-color-warning" role="status">This color may be hard to read over some photos.</p>
      )}
    </div>
  );
}
