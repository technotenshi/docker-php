# docker-php

Docker images for PHP 8.0 on Ubuntu Bionic, available as CLI and PHP-FPM variants. PHP packages come from the `ondrej/php` PPA.

## Images

| Variant | Build context | Includes |
| --- | --- | --- |
| CLI | `8.0/ubuntu/cli` | PHP CLI, Composer, Git, curl, unzip, and CA certificates |
| FPM | `8.0/ubuntu/fpm` | The CLI image plus PHP-FPM and container-specific pool configuration |

Both variants include the curl, mbstring, OPcache, readline, Xdebug, XML, and ZIP PHP packages.

## Build

Run these commands from the repository root with Docker running:

```sh
docker build -t technomike/php8.0-cli 8.0/ubuntu/cli
docker build -t php8.0-fpm:local 8.0/ubuntu/fpm
```

Build the CLI image first: the FPM Dockerfile uses `FROM technomike/php8.0-cli`. If you change that local image name, update the FPM base reference too. Use the variant directories as build contexts so `COPY overrides.conf` can find its source file.

Builds require network access to Ubuntu package repositories, the PHP PPA, and the Composer installer.

## Use the CLI image

Start the interactive PHP shell:

```sh
docker run --rm -it technomike/php8.0-cli
```

Run a script or Composer against the current directory:

```sh
docker run --rm -v "$PWD:/app" -w /app technomike/php8.0-cli php script.php
docker run --rm -v "$PWD:/app" -w /app technomike/php8.0-cli composer install
```

## Use the FPM image

Start FPM with your application mounted:

```sh
docker run --rm --name php-fpm -v "$PWD:/app" php8.0-fpm:local
```

FPM listens on FastCGI port `9000`. Connect a web server through a shared Docker network and configure its script paths to match the application paths inside the FPM container. Serving HTTP requires a separate web server.

The bundled `8.0/ubuntu/fpm/overrides.conf` keeps FPM in the foreground, directs access and error logs to container stderr, captures worker output, and preserves environment variables for workers. The image uses `SIGQUIT` for graceful shutdown.

## Validate changes

After building, check the runtime, extensions, Composer, and FPM configuration:

```sh
docker run --rm technomike/php8.0-cli php -v
docker run --rm technomike/php8.0-cli php -m
docker run --rm technomike/php8.0-cli composer --version
docker run --rm php8.0-fpm:local php-fpm8.0 -t
```

There is no automated test suite. See [AGENTS.md](AGENTS.md) for contributor guidelines.
