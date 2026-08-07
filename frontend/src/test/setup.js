import '@testing-library/jest-dom/vitest';

// jsdom doesn't implement matchMedia, which antd's Select/Switch/etc query
// during layout — without this, rendering antd components under jsdom throws.
if (!window.matchMedia) {
  window.matchMedia = (query) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  });
}
