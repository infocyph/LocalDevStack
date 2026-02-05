ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm-alpine

LABEL org.opencontainers.image.source="https://github.com/infocyph/LocalDock"
LABEL org.opencontainers.image.description="PHP FPM Alpine"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"

ARG USERNAME=dockery
ENV USERNAME=${USERNAME}
ARG LINUX_PKG
ARG LINUX_PKG_VERSIONED
ARG PHP_EXT
ARG PHP_EXT_VERSIONED
ARG UID=1000
ARG GID=1000
ENV GIT_USER_NAME="" \
    GIT_USER_EMAIL="" \
    GIT_SAFE_DIR_PATTERN="/app/*" \
    GIT_CREDENTIAL_STORE="/home/${USERNAME}/.git-credentials" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/games:$PATH" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

ADD https://raw.githubusercontent.com/infocyph/Scriptomatic/master/bash/php-cli-setup.sh /usr/local/bin/cli-setup.sh
RUN apk add --no-cache bash && \
  bash /usr/local/bin/cli-setup.sh "${USERNAME}" "${PHP_VERSION}" && \
  rm -f /usr/local/bin/cli-setup.sh && \
  rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

USER ${USERNAME}
RUN sudo /usr/local/bin/git-default
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/php-entry"]
CMD ["php-fpm"]