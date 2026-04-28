# AeroStore - E-Commerce DevOps Project

AeroStore is a minimal, container-ready e-commerce web application built for practicing and implementing modern DevOps workflows (Docker, Kubernetes, CI/CD). 

## 🚀 Tech Stack

- **Frontend**: React, Vite, Vanilla CSS (Premium Glassmorphism Design)
- **Backend**: Node.js, Express
- **Database**: Mock JSON Data (`products.json`)
- **Infrastructure** (Upcoming): Docker, Kubernetes, GitHub Actions

## 🏗️ Architecture

The project consists of two main decoupled services:

1. **Backend API (`/backend`)**: Serves product data and handles simulated business logic.
2. **Frontend UI (`/frontend`)**: A React SPA that consumes the backend API and provides a modern shopping experience with a client-side cart.

## 💻 Local Development

To run the application locally without containers:

### 1. Start the Backend API
```bash
cd backend
npm install
npm start
```
The API will run on `http://localhost:3001`

### 2. Start the Frontend UI
```bash
cd frontend
npm install
npm run dev
```
The frontend will run on `http://localhost:5173`

## 🐳 DevOps Pipeline (In Progress)

This project is currently in **Phase 1**. The upcoming phases will introduce:
- **Phase 2**: Dockerizing both the frontend and backend.
- **Phase 3**: Writing Kubernetes manifests (`Deployments`, `Services`).
- **Phase 4**: Automating the CI/CD pipeline using GitHub Actions.
- **Phase 5**: Cloud deployment and load testing.
