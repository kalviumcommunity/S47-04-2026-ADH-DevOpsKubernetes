# Git Branching Strategy & Commit Conventions

This document defines the version control practices followed in the AeroStore DevOps project.

---

## Branching Strategy

We follow a **feature-branch workflow** where `main` is always the stable, deployable branch. All work is done in isolated branches and merged via Pull Requests.

### Branch Naming Convention

| Prefix | Purpose | Example |
|---|---|---|
| `concept-*` | Documentation / learning concepts | `concept-1-artifact-flow` |
| `feature-*` | New features or app changes | `feature-cart-sidebar` |
| `devops-*` | Infrastructure / pipeline work | `devops-setup-proof` |
| `fix-*` | Bug fixes | `fix-cors-headers` |
| `cicd-*` | CI/CD pipeline changes | `cicd-pipeline-plan` |

### Rules
- **Never push directly to `main`** — all changes go through branches and PRs.
- Each branch represents **one logical unit of work** (not a mix of unrelated changes).
- Branch names should **communicate intent** — a reviewer should understand the purpose before opening the PR.

---

## Commit Message Conventions

We follow a lightweight version of **Conventional Commits**:

```
<type>: <short description>
```

### Commit Types

| Type | When to Use |
|---|---|
| `feat` | Adding a new feature |
| `fix` | Fixing a bug |
| `docs` | Documentation only changes |
| `chore` | Maintenance, config, cleanup |
| `ci` | CI/CD pipeline changes |
| `refactor` | Code restructuring (no behavior change) |

### Examples
```
feat: add product grid and cart sidebar to frontend
docs: add Concept-1 Artifact Flow documentation
ci: add GitHub Actions CI workflow
fix: resolve CORS issue on backend API
chore: clean up unused Vite template files
```

### Rules
- Each commit should represent **one coherent change**.
- Messages should explain **why**, not just restate filenames.
- Avoid generic messages like `update files` or `fix stuff`.

---

## Repository Structure

```
S47-04-2026-ADH-DevOpsKubernetes/
├── backend/                  # Node.js Express API
│   ├── index.js              # Server entry point
│   ├── products.json         # Mock product data (15 items)
│   └── package.json
├── frontend/                 # React (Vite) SPA
│   ├── src/
│   │   ├── App.jsx           # Main application component
│   │   └── App.css           # Styling
│   └── package.json
├── docs/                     # Documentation & concept write-ups
│   ├── README[Concept-1,Akshit].md
│   ├── README[Concept-2,Akshit].md
│   ├── README[Concept-3,Akshit].md
│   └── CICD-Pipeline-Plan.md
├── devops-setup/             # Environment setup proof
│   ├── README.md
│   └── Setup-test.png
├── .gitignore
└── README.md                 # Project overview (this repo's root)
```

---

## PR Workflow

1. Create a branch from `main` with a descriptive name.
2. Make focused commits with clear messages.
3. Push the branch and open a Pull Request on GitHub.
4. PR is reviewed, then merged into `main`.
5. Pull latest `main` locally before starting next task.

This ensures `main` is always stable, every change is traceable, and the commit history tells a clear story of the project's evolution.
