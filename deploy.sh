#!/usr/bin/env bash
set -e

cd frontend
npm run build
cd ..

rsync -avz --delete -e "ssh -i fellowscript-ec2-key.pem" \
  frontend/dist/assets/ ubuntu@44.216.136.112:/var/www/html/assets/

scp -i fellowscript-ec2-key.pem \
  frontend/dist/index.html ubuntu@44.216.136.112:/var/www/html/index.html
