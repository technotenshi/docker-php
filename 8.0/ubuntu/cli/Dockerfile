FROM ubuntu:bionic

LABEL maintainer="miguel@digitec.ws"

ENV TERM=linux
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get -y update && apt-get -y upgrade

RUN apt-get install -y --no-install-recommends software-properties-common gnupg

RUN add-apt-repository ppa:ondrej/php

RUN apt-get -y update

RUN apt-get -y --no-install-recommends install \
        ca-certificates \
        git \
        curl \
        unzip

RUN apt-get -y --no-install-recommends install \
        php8.0-cli \
        php8.0-curl \
        php8.0-mbstring \
        php8.0-opcache \
        php8.0-readline \
        php8.0-xdebug \
        php8.0-xml \
        php8.0-zip

RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && composer clear-cache

RUN apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* ~/.composer

CMD ["php", "-a"]