FROM technomike/php8.0-cli

RUN apt-get update \
    && apt-get -y --no-install-recommends install php8.0-fpm \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/*

STOPSIGNAL SIGQUIT

COPY overrides.conf /etc/php/8.0/fpm/pool.d/z-overrides.conf

CMD ["/usr/sbin/php-fpm8.0", "-O" ]

# Open up fcgi port
EXPOSE 9000