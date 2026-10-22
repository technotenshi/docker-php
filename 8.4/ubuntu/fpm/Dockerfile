ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# Refuse an unpatched or mismatched CLI base before asking apt for FPM.
RUN set -eu; \
    php -r 'exit(PHP_VERSION_ID >= 80427 && PHP_VERSION_ID < 80500 ? 0 : 1);' \
        || { echo "ERROR: inherited PHP runtime must be >= 8.4.27 and < 8.5.00 (CVE-2026-109618, CVE-2026-109619); rebuild the matching PHP 8.4 CLI/FPM pair from the current PPA." >&2; exit 1; }; \
    common_version="$(dpkg-query -W -f='${Version}' php8.4-common)" \
        || { echo "ERROR: php8.4-common is missing; rebuild the matching PHP 8.4 CLI/FPM pair." >&2; exit 1; }; \
    for package in php8.4-cli php8.4-curl php8.4-mbstring php8.4-opcache php8.4-readline php8.4-xml php8.4-zip; do \
        package_version="$(dpkg-query -W -f='${Version}' "$package")" \
            || { echo "ERROR: $package is missing; rebuild the matching PHP 8.4 CLI/FPM pair." >&2; exit 1; }; \
        [ "$package_version" = "$common_version" ] \
            || { echo "ERROR: $package version $package_version does not match php8.4-common $common_version; rebuild the matching PHP 8.4 CLI/FPM pair." >&2; exit 1; }; \
    done; \
    apt-get update; \
    apt-get install -y --no-install-recommends "php8.4-fpm=${common_version}" \
        || { echo "ERROR: php8.4-fpm ${common_version} is unavailable in the PPA; rebuild the matching CLI/FPM pair from the current PPA." >&2; exit 1; }; \
    for package in php8.4-cli php8.4-common php8.4-curl php8.4-mbstring php8.4-opcache php8.4-readline php8.4-xml php8.4-zip php8.4-fpm; do \
        package_version="$(dpkg-query -W -f='${Version}' "$package")" \
            || { echo "ERROR: unable to determine installed version for $package; rebuild the matching PHP 8.4 CLI/FPM pair." >&2; exit 1; }; \
        [ "$package_version" = "$common_version" ] \
            || { echo "ERROR: $package version $package_version does not match inherited php8.4-common $common_version; rebuild the matching PHP 8.4 CLI/FPM pair." >&2; exit 1; }; \
    done; \
    fpm_version="$(php-fpm8.4 -v | sed -n '1s/^PHP \([^ ]*\).*/\1/p')"; \
    cli_version="$(php -r 'echo PHP_VERSION;')"; \
    [ "$fpm_version" = "$cli_version" ] \
        || { echo "ERROR: php-fpm8.4 runtime $fpm_version does not match CLI runtime $cli_version; rebuild the matching PHP 8.4 CLI/FPM pair." >&2; exit 1; }; \
    php -r 'exit(PHP_VERSION_ID >= 80427 && PHP_VERSION_ID < 80500 ? 0 : 1);' \
        || { echo "ERROR: PHP runtime must be >= 8.4.27 and < 8.5.00 (CVE-2026-109618, CVE-2026-109619); rebuild the matching PHP 8.4 CLI/FPM pair." >&2; exit 1; }; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/*

STOPSIGNAL SIGQUIT

COPY overrides.conf /etc/php/8.4/fpm/pool.d/z-overrides.conf

CMD ["/usr/sbin/php-fpm8.4", "-O" ]

# Open up fcgi port
EXPOSE 9000
