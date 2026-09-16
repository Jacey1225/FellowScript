// Guard the whole file for `// @vitest-environment node` test files (e.g.
// homeSeo.build.test.js, which needs real Node/esbuild rather than jsdom) --
// this setupFiles entry is global per vitest.config.js and would otherwise
// throw before those files' own tests ever run, since `window`/jest-dom's
// DOM matchers don't apply outside a DOM environment.
if (typeof window !== 'undefined') {
  await import('@testing-library/jest-dom/vitest');

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
}
