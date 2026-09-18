ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm-alpine

LABEL org.opencontainers.image.source="https://github.com/infocyph/LocalDevStack"
LABEL org.opencontainers.image.description="PHP FPM Alpine"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"

ARG USERNAME=dockery
ENV USERNAME=${USERNAME}
ARG PHP_PROFILE_KEY=84
ARG LINUX_PKG
ARG LINUX_PKG_VERSIONED
ARG PHP_EXT
ARG PHP_EXT_VERSIONED
ARG UID=1000
ARG GID=1000
ARG SCRIPTOMATIC_REF=main
ARG SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT=10
ARG SCRIPTOMATIC_DOWNLOAD_MAX_TIME=120
ARG SCRIPTOMATIC_DOWNLOAD_RETRIES=3
ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/games:$PATH" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    GIT_CONFIG_GLOBAL=/git-config/.gitconfig \
    COMPOSER_HOME=/home/${USERNAME}/.composer/php${PHP_PROFILE_KEY}

RUN set -eux; \
    apk add --no-cache bash curl; \
    bootstrap="$(mktemp /tmp/scriptomatic-php.XXXXXX)"; \
    curl --fail --silent --show-error --location \
      --connect-timeout "${SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT}" \
      --max-time "${SCRIPTOMATIC_DOWNLOAD_MAX_TIME}" \
      --retry "${SCRIPTOMATIC_DOWNLOAD_RETRIES}" \
      --retry-delay 1 \
      --retry-connrefused \
      "https://raw.githubusercontent.com/infocyph/Scriptomatic/${SCRIPTOMATIC_REF}/bash/php-cli-setup.sh" \
      -o "$bootstrap"; \
    test -s "$bootstrap"; \
    bash -n "$bootstrap"; \
    UID="${UID}" \
    GID="${GID}" \
    LINUX_PKG="${LINUX_PKG}" \
    LINUX_PKG_VERSIONED="${LINUX_PKG_VERSIONED}" \
    PHP_EXT="${PHP_EXT}" \
    PHP_EXT_VERSIONED="${PHP_EXT_VERSIONED}" \
    PHP_PROFILE_KEY="${PHP_PROFILE_KEY}" \
    SCRIPTOMATIC_REF="${SCRIPTOMATIC_REF}" \
    SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT="${SCRIPTOMATIC_DOWNLOAD_CONNECT_TIMEOUT}" \
    SCRIPTOMATIC_DOWNLOAD_MAX_TIME="${SCRIPTOMATIC_DOWNLOAD_MAX_TIME}" \
    SCRIPTOMATIC_DOWNLOAD_RETRIES="${SCRIPTOMATIC_DOWNLOAD_RETRIES}" \
      bash "$bootstrap" "${USERNAME}" "${PHP_VERSION}"; \
    rm -f "$bootstrap"

USER ${USERNAME}
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/php-entry"]
CMD ["php-fpm"]
