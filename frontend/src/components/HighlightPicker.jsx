import React from 'react';
import { Button, Divider } from 'antd';

const COLORS = [
  '#F5C842', '#E8861A', '#4CAF78', '#E0607E', '#5B9BD5',
];

export default function HighlightPicker({ visible, position, onColor, onClear }) {
  if (!visible) return null;

  return (
    <div
      className="hl-picker"
      style={{ left: position.x, top: position.y }}
      onClick={e => e.stopPropagation()}
    >
      {COLORS.map(color => (
        <div
          key={color}
          className="hl-swatch"
          style={{ background: color }}
          data-color={color}
          onClick={() => onColor(color)}
        />
      ))}
      <div className="hl-divider" />
      <button className="hl-clear" onClick={onClear} title="Clear highlight">✕</button>
    </div>
  );
}
