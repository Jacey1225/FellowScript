import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import fs from 'fs';
import path from 'path';

// Custom plugin: serve ../data/* from /data/ in dev
function serveDataDir() {
  return {
    name: 'serve-data-dir',
    configureServer(server) {
      server.middlewares.use('/data', (req, res, next) => {
        const file = path.resolve(__dirname, '../data', req.url.replace(/^\//, ''));
        if (fs.existsSync(file)) {
          const ext = path.extname(file);
          const types = { '.json': 'application/json', '.mp4': 'video/mp4', '.svg': 'image/svg+xml' };
          res.setHeader('Content-Type', types[ext] || 'application/octet-stream');
          fs.createReadStream(file).pipe(res);
        } else {
          next();
        }
      });
    },
  };
}

export default defineConfig(({ command, mode }) => {
  // Configuration Q4 (fail fast, no implicit defaults), task
  // 20260909-website-seo: VITE_SITE_URL feeds src/config.js's SITE_URL,
  // which drives <link rel="canonical">/Open Graph/JSON-LD across every
  // route. A production build shipped with that missing would silently
  // bake a placeholder/localhost canonical domain into the deployed site,
  // so refuse to build rather than let that happen. Scoped to `build`
  // only -- `npm run dev` doesn't load .env.production and doesn't need
  // this set (src/config.js's dev-only fallback covers it there).
  if (command === 'build') {
    const env = loadEnv(mode, process.cwd(), '');
    if (!env.VITE_SITE_URL) {
      throw new Error(
        'VITE_SITE_URL is required to build the frontend (see frontend/.env.production) -- ' +
        'refusing to build with an implicit/placeholder canonical domain.'
      );
    }
  }

  return {
    plugins: [react(), serveDataDir()],
    build: { outDir: 'dist' },
  };
});
