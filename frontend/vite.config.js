import { defineConfig } from 'vite';
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

export default defineConfig({
  plugins: [react(), serveDataDir()],
  build: { outDir: 'dist' },
});
