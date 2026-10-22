FROM ubuntu:24.04

LABEL maintainer="miguel@digitec.ws"

ENV TERM=linux
ARG DEBIAN_FRONTEND=noninteractive

# Install certificate and repository tooling before adding the signed Ondrej PPA.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        software-properties-common \
        gnupg \
    && add-apt-repository -y ppa:ondrej/php \
    && apt-get update

RUN set -eu; \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        unzip

RUN set -eu; \
    apt-get install -y --no-install-recommends \
        php8.4-cli \
        php8.4-common \
        php8.4-curl \
        php8.4-mbstring \
        php8.4-opcache \
        php8.4-readline \
        php8.4-xml \
        php8.4-zip \
        php8.4-xdebug; \
    php -r 'exit(PHP_VERSION_ID >= 80427 && PHP_VERSION_ID < 80500 ? 0 : 1);' \
        || { echo "ERROR: PHP runtime must be >= 8.4.27 and < 8.5.00 (CVE-2026-109618, CVE-2026-109619); check the Ondrej PPA." >&2; exit 1; }; \
    common_version="$(dpkg-query -W -f='${Version}' php8.4-common)"; \
    for package in php8.4-cli php8.4-curl php8.4-mbstring php8.4-opcache php8.4-readline php8.4-xml php8.4-zip; do \
        package_version="$(dpkg-query -W -f='${Version}' "$package")" \
            || { echo "ERROR: unable to determine installed version for $package" >&2; exit 1; }; \
        [ "$package_version" = "$common_version" ] \
            || { echo "ERROR: $package version $package_version does not match php8.4-common $common_version" >&2; exit 1; }; \
    done

RUN set -eu; \
    composer_tmp="/tmp/composer-2.10.3.phar"; \
    curl -fsSL "https://getcomposer.org/download/2.10.3/composer.phar" -o "$composer_tmp"; \
    echo "7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6  ${composer_tmp}" | sha256sum -c -; \
    php "$composer_tmp" --version; \
    install -m 0755 "$composer_tmp" /usr/local/bin/composer; \
    printf 'Composer version: %s\nComposer SHA-256: %s\n' "2.10.3" "7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6"; \
    rm -f "$composer_tmp"

RUN apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* ~/.composer

CMD ["php", "-a"]
