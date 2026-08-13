# -- Build Stage -------------------------------------------------------------
# NOTE: hexpm rotates snapshot-dated tags — keep in sync with the CI
# workflow's container image when bumping.
FROM hexpm/elixir:1.18.4-erlang-27.2.4-debian-bookworm-20260803-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && \
    apt-get install -y build-essential git && \
    mix local.hex --force && \
    mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod

# Cache dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Compile configuration
COPY config config
COPY lib lib
COPY priv priv

# Compile release
RUN mix compile
RUN mix release

# -- Runtime Stage -----------------------------------------------------------
FROM debian:bookworm-slim

WORKDIR /app

# Install runtime dependencies for the "Dark Factory"
# - git: worktree management
# - bubblewrap: ghost sandboxing (GiTF.Sandbox.Bubblewrap)
# - curl/ca-certificates: API calls
# - openssl: BEAM crypto
# - locales: encoding
# - inotify-tools: :fs dep filesystem watching on Linux
# - nodejs/npm: required by the Claude/Copilot CLIs (CLI execution mode)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      bubblewrap \
      curl \
      ca-certificates \
      openssl \
      libncurses6 \
      locales \
      inotify-tools \
      nodejs \
      npm && \
    rm -rf /var/lib/apt/lists/*

# Install the Claude Code CLI so CLI-mode ghosts can run in-container.
# (API mode via ReqLLM needs no CLI; this makes both modes work.)
RUN npm install -g @anthropic-ai/claude-code || \
    echo "WARN: claude CLI install failed; container supports API mode only"

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/gitf .

# Create gitf data directories
RUN mkdir -p /data/gitf/store /data/gitf/worktrees /data/gitf/logs
ENV GITF_HOME=/data/gitf

# Server configuration (overridable at runtime)
ENV GITF_PORT=4000
ENV GITF_HOST=0.0.0.0

# Expose Dashboard + API port
EXPOSE 4000

# Container health probe hits the readiness endpoint.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:4000/api/v1/health || exit 1

# Set entrypoint
CMD ["bin/gitf", "start"]
