FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# Base system deps
RUN apt-get update && apt-get install -y \
    curl wget git ca-certificates gnupg \
    python3 python3-pip rsync postgresql-client \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libdbus-1-3 libatspi2.0-0 \
    libx11-6 libxcomposite1 libxdamage1 libxext6 \
    libxfixes3 libxrandr2 libgbm1 libxcb1 \
    libxkbcommon0 libpango-1.0-0 libcairo2 libasound2 \
    && rm -rf /var/lib/apt/lists/*

# uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest

WORKDIR /workspace

# Create venv OUTSIDE /workspace so it is not shadowed by the volume mount
# camel-ai brings: openai, pyyaml, httpx, tiktoken, etc.
RUN uv venv /opt/venv && uv pip install --python /opt/venv/bin/python \
    "camel-ai" \
    "anthropic" \
    "psycopg2-binary" \
    "openpyxl" \
    "python-docx" \
    "python-pptx" \
    "termcolor" \
    "aiofiles" \
    "psutil" \
    "addict" \
    "arxiv" \
    "bibtexparser" \
    "canvasapi" \
    "prompt_toolkit" \
    "mcp==1.9.0"


ENV PATH="/opt/venv/bin:$PATH"
ENV VIRTUAL_ENV="/opt/venv"

# CAMEL token counting pulls tiktoken encodings (o200k for gpt-4o-mini fallback).
# Bake them into the image so task containers do not hit Azure on every cold start.
ENV TIKTOKEN_CACHE_DIR=/opt/tiktoken_cache
RUN mkdir -p /opt/tiktoken_cache \
    && python -c "import tiktoken; tiktoken.get_encoding('o200k_base'); tiktoken.get_encoding('cl100k_base')" \
    && test -n "$(ls -A /opt/tiktoken_cache)"
# Fail the build if encodings still require network.
RUN --network=none python -c "import tiktoken; assert tiktoken.get_encoding('o200k_base').n_vocab > 0; assert tiktoken.get_encoding('cl100k_base').n_vocab > 0"

# Build Node-based and Python MCP servers from /opt/local_servers
# (keeps compiled artifacts outside the volume-mounted /workspace)
COPY local_servers/ /opt/local_servers/
RUN set -eu; for dir in \
        /opt/local_servers/Calendar-Autoauth-MCP-Server \
        /opt/local_servers/google-forms-mcp \
        /opt/local_servers/youtube-mcp-server \
        /opt/local_servers/filesystem \
        /opt/local_servers/HowToCook-mcp \
        /opt/local_servers/12306-mcp \
        /opt/local_servers/mcp-canvas-lms \
        /opt/local_servers/notion-mcp-server \
        /opt/local_servers/mcp-npx-fetch \
        /opt/local_servers/playwright-mcp \
        /opt/local_servers/woocommerce-mcp \
        /opt/local_servers/servers; do \
    test -f "$dir/package.json" && \
        echo "=== $dir ===" && cd "$dir" && \
        if [ -f package-lock.json ]; then npm ci; else npm install; fi && \
        npm run build --if-present && cd /workspace; \
done

# Browser binaries are versioned with the Node Playwright package used by the
# MCP server. Installing through the global Python package downloads a
# different revision and leaves browser_navigate unusable.
RUN cd /opt/local_servers/playwright-mcp && npx playwright install chromium

RUN set -eu; for dir in \
        /opt/local_servers/arxiv-mcp-server \
        /opt/local_servers/arxiv-latex-mcp \
        /opt/local_servers/yahoo-finance-mcp \
        /opt/local_servers/emails-mcp \
        /opt/local_servers/mcp-snowflake-server \
        /opt/local_servers/mcp-scholarly \
        /opt/local_servers/Office-Word-MCP-Server \
        /opt/local_servers/Office-PowerPoint-MCP-Server \
        /opt/local_servers/excel-mcp-server \
        /opt/local_servers/pdf-tools-mcp \
        /opt/local_servers/mcp-youtube-transcript \
        /opt/local_servers/cli-mcp-server \
        /opt/local_servers/mcp-google-sheets; do \
    test -f "$dir/pyproject.toml" && \
        echo "=== $dir ===" && cd "$dir" && uv sync && cd /workspace; \
done

# The YAML configs below execute these exact files. Fail the image build instead
# of discovering a silently skipped TypeScript build during a benchmark run.
RUN test -f /opt/local_servers/mcp-canvas-lms/build/index.js \
    && test -f /opt/local_servers/12306-mcp/build/index.js \
    && test -f /opt/local_servers/notion-mcp-server/bin/cli.mjs \
    && test -f /opt/local_servers/mcp-npx-fetch/dist/index.js \
    && test -f /opt/local_servers/playwright-mcp/lib/program.js \
    && test -f /opt/local_servers/woocommerce-mcp/dist/index.js

# Copy project code
COPY . .

# Optional build-time pin: docker build --build-arg GYM_REVISION=$(git rev-parse HEAD) ...
ARG GYM_REVISION=unknown
LABEL org.toolathlon.gym.revision=$GYM_REVISION

CMD ["/bin/bash"]
