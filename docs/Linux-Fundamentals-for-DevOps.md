# Linux Fundamentals for DevOps

> Why every DevOps engineer needs to think in Linux, not just type Linux commands.

---

## Why Linux Matters in DevOps

Most DevOps infrastructure runs on Linux — CI runners (GitHub Actions, GitLab CI), Docker containers, Kubernetes nodes, cloud VMs, and build agents all sit on top of a Linux kernel. Even when higher-level tools abstract the complexity, the moment something breaks — a pipeline fails, a container won't start, a deployment hangs — you're debugging **Linux**.

Common failure causes that trace back to Linux knowledge gaps:

- **Misconfigured paths** → build can't find binaries or config files
- **Wrong permissions** → scripts won't execute, services can't read secrets
- **Zombie processes** → containers appear healthy but are stuck
- **Port conflicts** → services silently fail to bind

Understanding the system state — where files live, who can access them, what's running, and how things communicate — is not optional. It's foundational.

---

## 1. The Linux Filesystem — Structure and Purpose

The Linux filesystem is **hierarchical and purpose-driven**. Unlike Windows where applications scatter files wherever they want, Linux enforces separation:

```
/
├── /bin         → Essential user binaries (ls, cp, cat)
├── /sbin        → System/admin binaries (iptables, fdisk)
├── /etc         → System-wide configuration files
├── /home        → User home directories
├── /var         → Variable data: logs, caches, spool
│   ├── /var/log    → System and application logs
│   └── /var/www    → Web server files (Apache/Nginx)
├── /tmp         → Temporary files (cleared on reboot)
├── /usr         → User programs and data
│   ├── /usr/bin    → Non-essential user binaries
│   └── /usr/local  → Locally compiled software
├── /opt         → Optional/third-party software
├── /proc        → Virtual filesystem for process info
└── /dev         → Device files
```

### Why This Matters for DevOps

| Scenario | Relevant Directory | Why |
|---|---|---|
| Writing a Dockerfile | `/usr/local/bin`, `/app` | You need to know where to `COPY` binaries and app code |
| Debugging a failed deploy | `/var/log` | Application and system logs live here |
| Mounting config into a container | `/etc` | Config files follow conventions (e.g., `/etc/nginx/nginx.conf`) |
| Checking available disk space | `/tmp`, `/var` | These fill up fast and break builds |
| Inspecting a running container | `/proc` | Process info is exposed as virtual files |

### Essential Navigation Commands

```bash
# Where am I?
pwd

# List files with details (permissions, owner, size, date)
ls -la

# List recursively to see the full tree
ls -laR /etc/nginx/

# Move around
cd /var/log
cd ~           # Jump to home directory
cd -           # Jump to previous directory

# Find files by name
find / -name "nginx.conf" -type f 2>/dev/null

# Find recently modified files (useful for debugging)
find /var/log -mmin -30 -type f    # Modified in last 30 minutes

# Check disk usage
df -h          # Filesystem usage (human-readable)
du -sh /var/*  # Size of each subdirectory in /var

# Read file contents
cat /etc/hostname                  # Dump entire file
head -20 /var/log/syslog           # First 20 lines
tail -f /var/log/syslog            # Follow log in real-time (essential!)
less /etc/passwd                   # Paginated viewing

# Search inside files
grep -r "error" /var/log/ --include="*.log"
grep -i "connection refused" /var/log/syslog
```

### Practical: Where Things Live in a Dockerized App

When you write a Dockerfile, you're essentially deciding where things go in the Linux filesystem:

```dockerfile
# Base image provides /usr/bin, /etc, etc.
FROM node:18-alpine

# Create app directory (convention: /app or /usr/src/app)
WORKDIR /app

# Copy dependency manifests first (layer caching!)
COPY package*.json ./

# Install deps → goes into /app/node_modules
RUN npm ci --production

# Copy application source
COPY . .

# Expose port (network communication point)
EXPOSE 3001

# Run the app
CMD ["node", "server.js"]
```

Every line here is a Linux filesystem decision. Knowing _why_ `/app` and not `/home/app` or `/tmp/app` matters when debugging volume mounts, permission issues, or layer caching.

---

## 2. Permissions, Ownership, and Access Control

Every file and directory in Linux has three layers of access control:

```
-rwxr-xr-- 1 akshit devops 4096 Apr 29 10:00 deploy.sh
│├──┤├──┤├──┤  │      │
│ U    G    O  owner  group
│
└─ file type (- = file, d = directory, l = symlink)
```

- **U (User/Owner)**: The user who owns the file
- **G (Group)**: Users in the file's group
- **O (Others)**: Everyone else

Each position is one of: `r` (read=4), `w` (write=2), `x` (execute=1), or `-` (none).

### Permission Breakdown

| Symbolic | Numeric | Meaning |
|---|---|---|
| `rwx` | 7 | Read + Write + Execute |
| `rw-` | 6 | Read + Write |
| `r-x` | 5 | Read + Execute |
| `r--` | 4 | Read only |
| `---` | 0 | No access |

### Commands for Permissions and Ownership

```bash
# View permissions
ls -la

# Change permissions (numeric)
chmod 755 deploy.sh    # Owner: rwx, Group: r-x, Others: r-x
chmod 600 secrets.env  # Owner: rw-, Group: ---, Others: ---
chmod 644 config.yaml  # Owner: rw-, Group: r--, Others: r--

# Change permissions (symbolic)
chmod +x deploy.sh     # Add execute for everyone
chmod u+x,g-w file     # Add execute for owner, remove write for group

# Change ownership
chown appuser:appgroup /app -R     # Recursively change owner and group
chown root:root /etc/nginx/nginx.conf

# Check who you are
whoami
id          # Shows uid, gid, and all groups
groups      # List groups current user belongs to
```

### Why Permissions Break DevOps Workflows

**Scenario 1: Script won't execute in CI**
```bash
# Problem: deploy.sh has no execute permission
$ ./deploy.sh
bash: ./deploy.sh: Permission denied

# Fix: Make it executable (and commit the permission to git!)
$ chmod +x deploy.sh
$ git add deploy.sh
$ git update-index --chmod=+x deploy.sh   # Git tracks permissions
```

**Scenario 2: Container runs as non-root but can't write logs**
```dockerfile
# Problem: App creates files as root during build, but runs as node user
FROM node:18-alpine
WORKDIR /app
COPY . .
RUN npm ci

# Fix: Create log directory with correct ownership BEFORE switching user
RUN mkdir -p /app/logs && chown -R node:node /app
USER node
CMD ["node", "server.js"]
```

**Scenario 3: Secrets file readable by everyone**
```bash
# DANGER: .env file with API keys is world-readable
-rw-r--r-- 1 root root 256 Apr 29 10:00 .env

# Fix: Lock it down
chmod 600 .env    # Only owner can read/write
```

### Common Permission Patterns in DevOps

| File Type | Recommended | Why |
|---|---|---|
| Shell scripts | `755` | Owner full, others can read/execute |
| Config files | `644` | Readable by all, writable by owner |
| Secret/env files | `600` | Owner only — security critical |
| SSL certificates | `600` or `400` | Must be protected from unauthorized reads |
| Log directories | `755` | Services write, admins can read |
| Application directories | `755` | Navigable by services, writable by owner |

---

## 3. Process and Network Inspection

### Process Inspection

In DevOps, you need to verify: _Is the service running? Is it stuck? Is something else using the port?_

```bash
# List all running processes (full format)
ps aux

# Filter for a specific process
ps aux | grep nginx
ps aux | grep node

# Real-time process monitor (like Task Manager)
top
htop          # Better version (install: apt install htop)

# Process tree — shows parent-child relationships
pstree -p

# Find what's using a specific port
lsof -i :3001
fuser 3001/tcp

# Kill a process
kill <PID>        # Graceful termination (SIGTERM)
kill -9 <PID>     # Force kill (SIGKILL) — last resort

# Check if a service is running (systemd)
systemctl status nginx
systemctl is-active docker
```

### Why Process Inspection Matters

- **CI/CD debugging**: Your pipeline step hangs → check if the process is stuck or zombie
- **Container health**: `docker exec <container> ps aux` shows what's really running inside
- **Resource leaks**: A build agent running out of memory → `top` shows which process is eating RAM

### Network Inspection

```bash
# Check listening ports — what services are bound and ready
ss -tlnp        # TCP listeners with process names
netstat -tlnp   # Alternative (older but widely available)

# Test if a port is reachable
curl -v http://localhost:3001/health
nc -zv localhost 3001         # Quick TCP check

# DNS resolution
nslookup api.example.com
dig api.example.com

# Check network interfaces and IPs
ip addr show
hostname -I       # Quick IP list

# Trace network path
traceroute api.example.com

# Check active connections
ss -tnp           # All established TCP connections
```

### Real-World Network Debugging

```bash
# Scenario: Your app deployed but health check fails
# Step 1: Is the process running?
ps aux | grep node
# → Yes, PID 1234

# Step 2: Is it listening on the expected port?
ss -tlnp | grep 3001
# → LISTEN  0  128  0.0.0.0:3001  → Yes, it's bound

# Step 3: Can you reach it locally?
curl http://localhost:3001/health
# → Connection refused → Something is wrong with the app itself

# Step 4: Check logs
tail -50 /var/log/app/error.log
# → "ECONNREFUSED 127.0.0.1:5432" → Database isn't running!

# Step 5: Check if database is up
ss -tlnp | grep 5432
# → Nothing → Start PostgreSQL
systemctl start postgresql
```

---

## 4. Putting It All Together — DevOps Scenarios

### Scenario A: Debugging a Failing Docker Build

```bash
# Build fails with "COPY failed: file not found"
# 1. Check what's in the build context
ls -la
find . -name "package.json"

# 2. Check .dockerignore isn't excluding needed files
cat .dockerignore

# 3. Verify file permissions
ls -la src/
```

### Scenario B: Container Starts But App Doesn't Respond

```bash
# 1. Get into the container
docker exec -it <container_name> /bin/sh

# 2. Check if process is running
ps aux

# 3. Check if port is bound
ss -tlnp

# 4. Check logs inside the container
cat /app/logs/error.log
# or from outside:
docker logs <container_name>

# 5. Check file permissions
ls -la /app/
# Maybe the app user can't read the config file
```

### Scenario C: CI Pipeline Health Check Script

```bash
#!/bin/bash
# A script you might run at the start of a CI pipeline
# to verify the runner environment is healthy

echo "=== System Info ==="
uname -a
whoami
pwd

echo "=== Disk Space ==="
df -h / /tmp

echo "=== Key Tools ==="
docker --version 2>/dev/null || echo "Docker: NOT FOUND"
node --version 2>/dev/null || echo "Node.js: NOT FOUND"
git --version

echo "=== Network ==="
ss -tlnp 2>/dev/null | head -10

echo "=== Running Processes ==="
ps aux | head -20
```

---

## Quick Reference Card

| Task | Command |
|---|---|
| Show current directory | `pwd` |
| List with permissions | `ls -la` |
| Find a file | `find / -name "file" 2>/dev/null` |
| Search in files | `grep -r "pattern" /path/` |
| Follow logs live | `tail -f /var/log/syslog` |
| Check disk space | `df -h` |
| Change permissions | `chmod 755 file` |
| Change ownership | `chown user:group file` |
| View all processes | `ps aux` |
| Find process on port | `lsof -i :PORT` |
| Check listening ports | `ss -tlnp` |
| Test connectivity | `curl -v http://host:port` |
| Kill a process | `kill PID` / `kill -9 PID` |

---

## Further Reading

- [Linux Filesystem Hierarchy Standard](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html)
- [Docker Best Practices: User Permissions](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
- [SS vs Netstat](https://www.redhat.com/sysadmin/ss-vs-netstat)

---

*Part of the AeroStore DevOps learning path — building operational fluency from Linux fundamentals through containerization to orchestration.*
