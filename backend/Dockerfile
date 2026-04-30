# ---- Backend Dockerfile ----
# Using Node.js Alpine for a small, secure base image (~50MB vs ~1GB for ubuntu)
# Alpine is a minimal Linux distro purpose-built for containers
FROM node:24-alpine

# Set working directory inside the container
WORKDIR /app

# Copy dependency files FIRST (layer caching optimization)
# Docker caches each layer — if package.json hasn't changed,
# the npm install layer is reused from cache, saving build time
COPY package.json package-lock.json ./

# Install production dependencies only (skip devDependencies)
RUN npm ci --only=production

# NOW copy the rest of the source code
# This layer changes frequently, so it comes AFTER npm install
# If we copied everything first, ANY code change would re-trigger npm install
COPY . .

# Document which port the app listens on
EXPOSE 3001

# Run the application
CMD ["node", "index.js"]