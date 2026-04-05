ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm-alpine

LABEL org.opencontainers.image.source="https://github.com/infocyph/LocalDevStack"
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
ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/games:$PATH" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    GIT_CONFIG_GLOBAL=/git-config/.gitconfig

ADD https://raw.githubusercontent.com/infocyph/Scriptomatic/master/bash/php-cli-setup.sh /usr/local/bin/cli-setup.sh
RUN apk add --no-cache bash && bash /usr/local/bin/cli-setup.sh "${USERNAME}" "${PHP_VERSION}"

USER ${USERNAME}
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/php-entry"]
CMD ["php-fpm"]
