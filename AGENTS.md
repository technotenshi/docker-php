# Repository Guidelines

## Project Structure & Module Organization

This repository defines Ubuntu-based PHP 8.0 container images. The `8.0/` directory contains `ubuntu/cli/Dockerfile` and `ubuntu/fpm/Dockerfile`. CLI images install PHP, extensions, and Composer; FPM images extend the corresponding `technomike/php<version>-cli` image. Each FPM directory includes `overrides.conf`, copied into PHP's pool configuration directory. `README.md` documents the image naming pattern. There are no application sources, assets, or dedicated test directories.

## Build, Test, and Development Commands

Run commands from the repository root with Docker available:

```sh
# Build the CLI base using the name referenced by the FPM Dockerfile.
docker build -t technomike/php8.0-cli 8.0/ubuntu/cli
# Build the matching FPM image.
docker build -t php8.0-fpm:local 8.0/ubuntu/fpm
# Check the CLI runtime and Composer.
docker run --rm technomike/php8.0-cli php -v
docker run --rm technomike/php8.0-cli composer --version
# Validate FPM configuration.
docker run --rm php8.0-fpm:local php-fpm8.0 -t
```

Use each variant directory as its build context so FPM's `COPY overrides.conf` resolves correctly. Build the matching CLI image before FPM.

## Coding Style & Naming Conventions

Follow existing Dockerfiles: uppercase instructions, one package per continuation line, eight-space package indentation, and four-space indentation for chained `&&` commands. Keep versioned package names, executable paths, and configuration destinations consistent. Use INI sections and semicolon comments in `overrides.conf`. Preserve the `<version>/ubuntu/<cli|fpm>/` layout. No formatter or linter is configured.

## Testing Guidelines

There is no automated test framework or coverage target. For each affected version, build both variants and run the smoke checks above. Use `php -m` to verify extension changes. For FPM behavior changes, also verify foreground startup and logs; configuration uses port 9000 and sends logs to container streams. Include validation results in the pull request.

## Commit & Pull Request Guidelines

Recent commits use short, lowercase action summaries, such as `adding php 8.0 fpm`; no formal commit prefix convention is evident. Keep commits focused. Pull requests should explain the change, identify affected versions and variants, link relevant issues, and list build and smoke-check results. Explain package or base-image changes and any external repository failures encountered during validation.
