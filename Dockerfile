# -- Build Stage -------------------------------------------------------------
FROM hexpm/elixir:1.18.1-erlang-27.2-debian-bookworm-20241202-slim as builder

WORKDIR /app

# Install build dependencies
RUN apt-get update &&
    apt-get install -y build-essential git &&
    mix local.hex --force &&
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
# - git: for worktree management
# - bubblewrap: for sandboxing
# - curl/ca-certificates: for API calls
# - openssl: for BEAM crypto
# - locales: for proper encoding
# - inotify-tools: required by :fs dep for filesystem watching on Linux
RUN apt-get update &&
    apt-get install -y --no-install-recommends
    git
    bubblewrap
    curl
    ca-certificates
    openssl
    libncurses5
    locales
    inotify-tools
    && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/gitf .

# Create gitf data directories
RUN mkdir -p /data/gitf/store /data/gitf/worktrees
ENV GITF_HOME=/data/gitf

# Server configuration (overridable at runtime)
ENV GITF_PORT=4000
ENV GITF_HOST=0.0.0.0

# Expose Dashboard + API port
EXPOSE 4000

# Set entrypoint
CMD ["bin/gitf", "start"]
