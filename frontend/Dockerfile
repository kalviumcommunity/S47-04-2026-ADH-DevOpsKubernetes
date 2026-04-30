# ---- Frontend Dockerfile (Multi-Stage Build) ----

# ============ STAGE 1: Build ============
# Use Node.js to install dependencies and build the Vite app
# Got Security vulnerabilities for node:20-alpine, so moving to node:24-alpine
FROM node:24-alpine AS builder

WORKDIR /app

# Copy dependency files FIRST for layer caching
# If these files haven't changed, Docker reuses the cached npm install layer
COPY package.json package-lock.json ./

# Install ALL dependencies (need devDependencies for build tools like vite, typescript)
RUN npm ci

# Copy source code and build the production bundle
COPY . .
RUN npm run build

# ============ STAGE 2: Serve ============
# Use nginx to serve the static files — no Node.js needed at runtime
# nginx:alpine is tiny (~7MB) and purpose-built for serving static content
FROM nginx:alpine

# Copy the built files from the builder stage into nginx's serve directory
COPY --from=builder /app/dist /usr/share/nginx/html

# Expose port 80 (nginx default)
EXPOSE 80

# nginx runs automatically with its default CMD
