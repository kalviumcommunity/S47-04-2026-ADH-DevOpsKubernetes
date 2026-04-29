# AeroStore — E-Commerce DevOps Project

A minimal, container-ready e-commerce application built to practice and implement modern DevOps workflows: Docker, Kubernetes, and CI/CD.

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | React, Vite |
| Backend | Node.js, Express |
| Data | Mock JSON (`products.json`) |
| CI/CD | GitHub Actions (planned) |
| Containers | Docker (planned) |
| Orchestration | Kubernetes (planned) |

## Repository Structure

```
├── backend/          # Express API serving mock product data
├── frontend/         # React SPA consuming the API
├── docs/             # Concept write-ups & pipeline documentation
├── devops-setup/     # Environment setup proof & screenshots
└── README.md
```

## Local Development

**Backend** (port 3001):
```bash
cd backend && npm install && npm start
```

**Frontend** (port 5173):
```bash
cd frontend && npm install && npm run dev
```

## Branch Strategy

All work is done via feature branches and merged through Pull Requests. See [docs/Git-Branching-Conventions.md](docs/Git-Branching-Conventions.md) for full details.

## Project Phases

| Phase | Focus | Status |
|---|---|---|
| 1 | App Setup (React + Node.js) | ✅ Complete |
| 2 | Dockerization | 🔜 Next |
| 3 | Kubernetes Manifests | Planned |
| 4 | CI/CD with GitHub Actions | Planned |
| 5 | Cloud Deployment & Load Testing | Planned |
