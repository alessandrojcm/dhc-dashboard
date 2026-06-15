# syntax=docker/dockerfile:1

# Build on Debian and install the BEAM toolchain through mise so Docker builds
# use the same versions pinned in the repo root `.mise.toml`.
ARG BUILDER_IMAGE="debian:bookworm-20250520-slim"
ARG RUNNER_IMAGE="debian:bookworm-20250520-slim"

FROM ${BUILDER_IMAGE} AS builder

WORKDIR /app

RUN apt-get update  \
    && apt-get -y --no-install-recommends install  \
        autoconf \
        build-essential \
        ca-certificates \
        curl \
        git \
        libncurses-dev \
        libssl-dev \
        locales \
        m4 \
        perl \
        unzip \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV MISE_DATA_DIR="/mise"
ENV MISE_CONFIG_DIR="/mise"
ENV MISE_CACHE_DIR="/mise/cache"
ENV MISE_INSTALL_PATH="/usr/local/bin/mise"
ENV PATH="/mise/shims:$PATH"
ENV MISE_YES="1"
ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"

RUN curl https://mise.run | sh

# Install only the BEAM tools needed to build the release. Other tools pinned in
# `.mise.toml` (Node, pnpm, fnox) are used elsewhere but are not needed here.
COPY .mise.toml ./
RUN mise trust -a && mise install erlang elixir

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

COPY apps/phoenix/mix.exs apps/phoenix/mix.lock ./
RUN mix deps.get --only ${MIX_ENV}

RUN mkdir config
COPY apps/phoenix/config/config.exs apps/phoenix/config/prod.exs config/
RUN mix deps.compile

COPY apps/phoenix/priv priv
COPY apps/phoenix/lib lib
COPY apps/phoenix/rel rel

RUN mix compile

# Runtime config must be copied after compilation so changing secrets/env config
# does not force a full rebuild of compiled modules.
COPY apps/phoenix/config/runtime.exs config/

RUN mix release

FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl gpg && \
    curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
      gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" > /etc/apt/sources.list.d/1password.list && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends 1password-cli && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /root/.gnupg && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen

ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8" \
    ECTO_IPV6="true" \
    ERL_AFLAGS="-proto_dist inet6_tcp" \
    FNOX_IF_MISSING="error" \
    FNOX_PROFILE="production" \
    HOME="/app" \
    MISE_DATA_DIR="/mise" \
    MISE_CONFIG_DIR="/mise" \
    MISE_CACHE_DIR="/mise/cache" \
    MISE_STATE_DIR="/mise/state" \
    MISE_INSTALL_PATH="/usr/local/bin/mise" \
    PATH="/mise/shims:${PATH}" \
    MISE_YES="1"

RUN curl https://mise.run | sh

WORKDIR /app
COPY .mise.toml fnox.toml ./
RUN mise trust -a && mise install fnox && chown -R nobody:root /mise /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/dhc ./

USER nobody

CMD ["fnox", "exec", "--profile", "production", "--", "/app/bin/dhc", "start"]
