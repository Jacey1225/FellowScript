# System Architecture Overview

FellowScript is a full-stack application with three clients (web, iOS, docs) backed by a single FastAPI server and a Postgres database, hosted on AWS EC2.

---

## Repository Layout

```
FellowScript/
├── api/                        # FastAPI backend (Python)
│   ├── main.py                 # App entry point, auth routes, lifespan
│   ├── db.py                   # DBManager, schema DDL, migrations
│   ├── schemas/                # Pydantic request/response models
│   ├── routes/                 # Thin HTTP handlers (APIRouter per domain)
│   └── backend/
│       ├── interactions/       # Business logic + DB managers
│       └── subscription/       # Subscription, limits, Stripe, Apple IAP
├── frontend/                   # React + Vite web app
│   ├── src/
│   │   ├── pages/              # Home, Reader, Account, SignIn, Privacy, Terms
│   │   ├── components/         # AppNav, NotesSidebar, MessagingSidebar, …
│   │   └── context/            # AuthContext (user session)
│   └── dist/                   # Built output (rsync'd to EC2 /var/www/html/)
├── FellowScript/               # Native iOS app (Swift / Xcode)
│   └── FellowScript/
│       ├── Models/             # Codable data models
│       ├── Services/           # NetworkService, StoreKitManager
│       ├── Auth/               # GoogleAuthSession, AppleAuth
│       └── Account/            # AccountView (profile + delete)
├── docs/                       # MkDocs documentation (this site)
└── mkdocs.yml
```

---

## Data Flow

```
Web (React)  ──┐
iOS (Swift)  ──┼──▶  FastAPI (EC2 :8000)  ──▶  Postgres (local)
               │            │
               │     WebSocket server ──▶ real-time messaging
               └──▶  Nginx (EC2 :80/443) ──▶ static frontend
```

---

## Layers

| Layer | Technology | Purpose |
|---|---|---|
| Frontend (web) | React 18 + Vite, Ant Design | UI, routing, state |
| Frontend (iOS) | Swift, SwiftUI | Native mobile client |
| API | FastAPI + Uvicorn | REST endpoints + WebSocket |
| Business logic | Python manager classes | Domain rules, DB queries |
| Database | PostgreSQL | All user-generated data |
| Auth | bcrypt (password), Google OAuth, Apple JWT | Three sign-in methods |
| Billing | Stripe Checkout (web), StoreKit 2 (iOS) | Subscription management |
| Hosting | AWS EC2 (Nginx + Uvicorn) | Web + API server |
| Docs | MkDocs + Material | GitHub Pages |

---

## Request Lifecycle (typical REST call)

1. Client sends HTTP request to `api.fellowscript.app:8000` (or EC2 IP)
2. FastAPI route handler in `routes/` validates the request via Pydantic schema
3. Handler instantiates the domain manager from `backend/interactions/`
4. Manager runs SQL via `DBManager` helpers (`lookup`, `insertion`, `update`, `delete`) or raw cursor for complex queries
5. Manager returns a plain dict; handler maps errors → `HTTPException`
6. FastAPI serialises the response to JSON

---

## Deployment

**Frontend** — `npm run build` in `frontend/`, then rsync `dist/` to EC2 `/var/www/html/`. Nginx serves the static files.

**Backend** — rsync changed Python files to EC2 `/home/ubuntu/fellowscript/api/`, then `sudo systemctl restart fellowscript`. Uvicorn runs as a systemd service inside the project virtualenv. Not containerized today — see [Docker Containerization Plan](docker-plan.md) for the reference plan to migrate this off manual rsync+systemd.

**Docs** — `.venv/bin/mkdocs gh-deploy --force` builds and force-pushes to the `gh-pages` branch of the GitHub repo. Live at `https://Jacey1225.github.io/FellowScript/`.
