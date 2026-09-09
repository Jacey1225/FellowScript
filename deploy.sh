#!/usr/bin/env bash
set -e

cd frontend
npm run build
cd ..

rsync -avz --delete -e "ssh -i fellowscript-ec2-key.pem" \
  frontend/dist/assets/ ubuntu@44.216.136.112:/var/www/html/assets/

scp -i fellowscript-ec2-key.pem \
  frontend/dist/index.html ubuntu@44.216.136.112:/var/www/html/index.html

# task 20260909-website-seo: robots.txt/sitemap.xml are new frontend/public/
# static files that Vite copies verbatim to dist/ root (same level as
# index.html) -- ship them the same narrow, per-file way as index.html
# above, rather than rsync'ing the whole dist/ root, so this doesn't touch
# other content that may already live in /var/www/html/ outside this repo's
# build (e.g. the legacy no-build pages/assets under frontend/js, frontend/css).
scp -i fellowscript-ec2-key.pem \
  frontend/dist/robots.txt ubuntu@44.216.136.112:/var/www/html/robots.txt

scp -i fellowscript-ec2-key.pem \
  frontend/dist/sitemap.xml ubuntu@44.216.136.112:/var/www/html/sitemap.xml
