---
description: Build the FellowScript frontend and deploy it to the EC2 server via rsync. Runs `npm run build` in frontend/, then syncs dist/ to ubuntu@44.216.136.112:/var/www/html/ using the PEM key at ~/Downloads/fellowscript-ec2-key.pem.
---

Build the FellowScript frontend and deploy it to EC2.

## Steps

1. Run the frontend build:
```bash
cd /Users/jaceysimpson/Vscode/FellowScript/frontend && npm run build
```

2. If the build succeeds, sync the dist directory to the server:
```bash
rsync -av --delete -e "ssh -i /Users/jaceysimpson/Downloads/fellowscript-ec2-key.pem -o StrictHostKeyChecking=no" /Users/jaceysimpson/Vscode/FellowScript/frontend/dist/ ubuntu@44.216.136.112:/var/www/html/
```

3. Report whether the build and deploy succeeded or failed. If the build failed, show the relevant error lines and do not attempt the rsync.

## Notes
- The EC2 server serves the frontend from `/var/www/html/`
- The backend API runs from `/home/ubuntu/fellowscript/` on port 8000
- To deploy backend changes (Python files), rsync them to `/home/ubuntu/fellowscript/` using the same key, then restart uvicorn: `pkill -f "uvicorn main:app"` followed by restarting it with nohup
