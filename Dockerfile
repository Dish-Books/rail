# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE="hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261027-slim"
ARG RUNNER_IMAGE="debian:trixie-20261027-slim"
ARG NODE_IMAGE="node:26.13.0-trixie-slim"

# Node for the sandbox. Trixie's is 20, and the browser driver agents run needs the global
# WebSocket that arrived in 22.
FROM ${NODE_IMAGE} AS node

# ------------------------------------------------------------------------------
# Build Stage
# ------------------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build

# Keep in step with mise.toml.
ARG PNPM_VERSION=12.16.1

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    nodejs \
    npm \
  && npm install -g "pnpm@${PNPM_VERSION}" \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib

RUN mix assets.deploy

COPY config/runtime.exs config/
RUN mix compile

RUN mix release rail

# ------------------------------------------------------------------------------
# Sandbox Stage
# ------------------------------------------------------------------------------
# What every agent, worktree setup and CI command runs in, as `rail-sandbox:latest`
# (scripts/deploy.sh). Rail's own image is built on it, so an agent finds the same
# tools in its sandbox as it did beside Rail, without Rail's release or environment.
FROM ${RUNNER_IMAGE} AS sandbox

# chromium for QA and demos; the build tools let mise compile a project's Erlang; python because
# agents reach for it to script whatever the shell makes awkward. The Postgres client is the shared
# server's major version, because a project's pg_dump must match it.
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    autoconf \
    build-essential \
    ca-certificates \
    chromium \
    curl \
    ffmpeg \
    git \
    inotify-tools \
    jq \
    libncurses-dev \
    libssl-dev \
    libstdc++6 \
    locales \
    m4 \
    openssh-client \
    openssl \
    postgresql-client-17 \
    python-is-python3 \
    python3 \
    python3-pip \
    python3-venv \
    unzip \
    xz-utils \
  && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

# Node and npm, for the browser driver in QA and demos and for any project script that wants them.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

RUN groupadd -g 1000 rail && \
    useradd -u 1000 -g rail -m -s /bin/bash rail

USER rail
WORKDIR /home/rail

# mise, from its official installer, into ~/.local/bin.
RUN curl -fsSL https://mise.run | sh

# Claude Code, pinned: the layer is cached and the auto-updater is off, so the
# version only moves when this does. Bump it to pick up a new model.
ARG CLAUDE_CODE_VERSION=2.1.316
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"

# prek on PATH, not only through mise. A pre-push hook calls prek by the path it
# was installed from, and falls back to a bare `prek` when that path is gone -
# which it is whenever the hook was written from a mise data dir that did not
# survive, such as a sandbox's own home. Keep in step with mise.toml.
ARG PREK_VERSION=0.5.9
RUN curl --proto '=https' --tlsv1.2 -LsSf \
    "https://github.com/j178/prek/releases/download/v${PREK_VERSION}/prek-installer.sh" \
  | PREK_NO_MODIFY_PATH=1 sh

ENV PATH=/home/rail/.local/bin:$PATH
ENV DISABLE_AUTOUPDATER=1

# ------------------------------------------------------------------------------
# Runner Stage
# ------------------------------------------------------------------------------
FROM sandbox AS runner

USER root
WORKDIR /app
RUN chown rail:rail /app
USER rail

COPY --from=build --chown=rail:rail /app/_build/prod/rel/rail ./

ENV PHX_SERVER=true
ENV PORT=4000
ENV MIX_ENV=prod

EXPOSE 4000

ENTRYPOINT ["/app/bin/rail"]
CMD ["start"]
