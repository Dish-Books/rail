# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE="hexpm/elixir:1.19.5-erlang-28.4.1-debian-bookworm-slim"
ARG RUNNER_IMAGE="debian:bookworm-slim"

# ------------------------------------------------------------------------------
# Build Stage
# ------------------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    nodejs \
    npm \
  && npm install -g pnpm \
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
# Runner Stage
# ------------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    ffmpeg \
    git \
    jq \
    libstdc++6 \
    locales \
    openssh-client \
    openssl \
  && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt-get update -y \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

RUN groupadd -g 1000 rail && \
    useradd -u 1000 -g rail -m -s /bin/bash rail

RUN mkdir -p /var/rail/worktrees /var/rail/scratch /app && \
    chown -R rail:rail /var/rail /app

COPY --from=build --chown=rail:rail /app/_build/prod/rel/rail ./

USER rail

ENV PHX_SERVER=true
ENV PORT=4000
ENV MIX_ENV=prod

EXPOSE 4000

ENTRYPOINT ["/app/bin/rail"]
CMD ["start"]
