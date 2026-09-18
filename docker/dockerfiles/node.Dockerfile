ARG NODE_VERSION=current
FROM node:${NODE_VERSION}-alpine

LABEL org.opencontainers.image.source="https://github.com/infocyph/LocalDevStack"
LABEL org.opencontainers.image.description="NodeJS Alpine"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"

ARG USERNAME=dockery
ENV USERNAME=${USERNAME}
ARG UID=1000
ARG GID=1000
ARG LINUX_PKG
ARG LINUX_PKG_VERSIONED
ARG NODE_GLOBAL
ARG NODE_GLOBAL_VERSIONED
ARG SCRIPTOMATIC_REF=main
ARG SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT=10
ARG SCRIPTOMATIC_DOWNLOAD_MAX_TIME=120
ARG SCRIPTOMATIC_DOWNLOAD_RETRIES=3
ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/games:$PATH" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    NPM_CONFIG_CACHE=/home/${USERNAME}/.npm \
    GIT_CONFIG_GLOBAL=/git-config/.gitconfig

RUN set -eux; \
    apk add --no-cache bash curl; \
    bootstrap="$(mktemp /tmp/scriptomatic-node.XXXXXX)"; \
    curl --fail --silent --show-error --location \
      --connect-timeout "${SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT}" \
      --max-time "${SCRIPTOMATIC_DOWNLOAD_MAX_TIME}" \
      --retry "${SCRIPTOMATIC_DOWNLOAD_RETRIES}" \
      --retry-delay 1 \
      --retry-connrefused \
      "https://raw.githubusercontent.com/infocyph/Scriptomatic/${SCRIPTOMATIC_REF}/bash/node-cli-setup.sh" \
      -o "$bootstrap"; \
    test -s "$bootstrap"; \
    bash -n "$bootstrap"; \
    resolved_node_version="$(node -v | sed 's/^v//')"; \
    UID="${UID}" \
    GID="${GID}" \
    LINUX_PKG="${LINUX_PKG}" \
    LINUX_PKG_VERSIONED="${LINUX_PKG_VERSIONED}" \
    NODE_GLOBAL="${NODE_GLOBAL}" \
    NODE_GLOBAL_VERSIONED="${NODE_GLOBAL_VERSIONED}" \
    SCRIPTOMATIC_REF="${SCRIPTOMATIC_REF}" \
    SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT="${SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT}" \
    SCRIPTOMATIC_DOWNLOAD_MAX_TIME="${SCRIPTOMATIC_DOWNLOAD_MAX_TIME}" \
    SCRIPTOMATIC_DOWNLOAD_RETRIES="${SCRIPTOMATIC_DOWNLOAD_RETRIES}" \
      bash "$bootstrap" "${USERNAME}" "$resolved_node_version"; \
    rm -f "$bootstrap"

USER ${USERNAME}
WORKDIR /app
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/node-entry"]
CMD []
