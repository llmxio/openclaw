FROM node:22-bookworm

# Install Bun (required for build scripts)
# RUN curl -fsSL https://bun.sh/install | bash
# ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app
RUN chown node:node /app

ARG OPENCLAW_DOCKER_APT_PACKAGES="curl ca-certificates wget gnupg lsb-release sudo build-essential"
ARG OPENCLAW_INSTALL_BROWSER="1"

# install base packages, node sudoers and optionally the Brave browser in one layer
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
    echo "node ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/node; \
    fi && \
    if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    | tee /etc/apt/sources.list.d/brave-browser-release.list && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends brave-browser && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=node:node ui/package.json ./ui/package.json
COPY --chown=node:node patches ./patches
COPY --chown=node:node scripts ./scripts

RUN mkdir -p /home/node && chown -R node:node /home/node

USER node
# Reduce OOM risk on low-memory hosts during dependency installation.
# Docker builds on small VMs may otherwise fail with "Killed" (exit 137).
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile && \
    pnpm rebuild && \
    npm rebuild better-sqlite3 --build-from-source

# copy source after dependencies so rebuilds are cached when changing code
COPY --chown=node:node . .
RUN OPENCLAW_PREFER_PNPM=1 pnpm build && \
    CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \
    echo >> /home/node/.bashrc && \
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /home/node/.bashrc && \
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && \
    brew install --quiet gcc && \
    brew install --quiet oven-sh/bun/bun && \
    OPENCLAW_PREFER_PNPM=1 pnpm ui:build && \
    ./node_modules/.bin/qmd status


# Expose the CLI binary without requiring npm global writes as non-root.
USER root
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw && \
    chmod 755 /app/openclaw.mjs


# Security hardening: Run as non-root user
# The node:22-bookworm image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges
USER node

ENV HOME=/home/node \
    NODE_ENV=production \
    HOMEBREW_NO_ENV_HINTS=1 \
    OPENCLAW_PREFER_PNPM=1

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
