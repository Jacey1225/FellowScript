// Text-level profile links (sender names, mentions, chips) sit inside a line of
// text, so they stay inline and let the surrounding line set the hit height
// (WCAG 2.5.8 inline exception). Avatar-sized targets use the 44px default.
export const INLINE_LINK_STYLE = { display: 'inline', minWidth: 0, minHeight: 0 };
