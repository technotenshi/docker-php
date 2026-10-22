# docker-php

Ubuntu 24.04 PHP 8.4 CLI and PHP-FPM container images. PHP packages come from the signed `ondrej/php` PPA. The former PHP 8.0 contexts have been retired; there are no compatibility aliases at the old `8.0/ubuntu/...` paths.

## Images

| Variant | Build context | Includes |
| --- | --- | --- |
| CLI | `8.4/ubuntu/cli` | PHP CLI, Composer 2.10.3, Git, curl, unzip, and CA certificates |
| FPM | `8.4/ubuntu/fpm` | The matching CLI image plus PHP-FPM and pool configuration |

Both images include curl, mbstring, OPcache, readline, Xdebug, XML, and ZIP PHP packages. Xdebug is versioned independently from the PHP core packages. The CLI keeps `php -a` as its default command. Xdebug remains installed for compatibility; PHP's JIT cannot be enabled while Xdebug is loaded, so the FPM image sets `opcache.jit_buffer_size=0` (`8.4/ubuntu/fpm/jit.ini`) to avoid a startup warning.

The image guards require `80427 <= PHP_VERSION_ID < 80500`, covering PHP 8.4.27 and later patch releases in the 8.4 branch. This is the fixed PHP 8.4 release for [CVE-2026-109618](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w) and [CVE-2026-109619](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp). The Trivy report is useful vulnerability evidence, but scanner silence does not prove that PPA packages contain those fixes; the build and smoke checks also inspect the runtime and package versions.

## Build and validate

Use the shared validation scripts from the repository root. Local validation requires Bash, Python 3, a local Docker Unix-socket endpoint, and the default Docker Buildx driver. Network access is needed for Ubuntu and PPA packages, the Composer PHAR, the Trivy image, and its vulnerability database. The smoke script owns the CLI and FPM build sequence, assigns unique tags, captures the CLI image ID and layers, and verifies that the parent identity is unchanged and the FPM layers begin with the captured CLI layers. `--pull=false` alone does not establish that the intended parent was used. The script also exercises CLI and live FastCGI behavior and checks runtime/package versions, required modules, Composer, environment forwarding, logs, PID 1, and graceful `SIGQUIT` shutdown.

The artifact directory must already exist and be empty. To validate while retaining the images for local use:

```sh
ARTIFACT_DIR=$(mktemp -d)
bash tests/smoke.sh "$ARTIFACT_DIR" --keep-images
bash tests/audit.sh "$ARTIFACT_DIR"
```

The successful smoke run writes `cli.tar`, `fpm.tar`, and `validation.json`. The report records the exact unique image tags and IDs, runtime and package versions, layers, Composer checksum, and FPM probe evidence. `--keep-images` retains the images only after all smoke checks and report/archive creation succeed; a failed smoke run removes only resources it created. Without `--keep-images`, the script removes its image tags after producing the report and archives. The audit requires both image archives and the smoke-generated `validation.json`; it ties scanned image IDs and package coverage to that report. It reads the archives without Docker socket access and writes `cli-trivy.json`, `fpm-trivy.json`, their stderr logs, and `audit-summary.json`. It refreshes and validates the vulnerability database before offline scans, and fails on scan or database errors. It also fails on any Critical or High finding whose ID is not listed in `tests/trivy-triaged.txt`; add an ID there (with the reason after `#`) only after independent triage shows it is not actionable and in scope.

For normal local use, retain the images and use the exact tags recorded in the report. This reads the tags without requiring `jq`:

```sh
CLI_IMAGE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cli"]["tag"])' "$ARTIFACT_DIR/validation.json")
FPM_IMAGE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fpm"]["tag"])' "$ARTIFACT_DIR/validation.json")
docker run --rm -it "$CLI_IMAGE"
docker run --rm -v "$PWD:/app" -w /app "$CLI_IMAGE" php script.php
docker run --rm -v "$PWD:/app" -w /app "$CLI_IMAGE" composer install
docker run --rm --name php-fpm -v "$PWD:/app" "$FPM_IMAGE"
```

To build the two images without the validation run (unvalidated; this skips every smoke and audit check), build the CLI first and pass it to FPM:

```sh
docker build -t php84-cli:local 8.4/ubuntu/cli
docker build --pull=false --build-arg BASE_IMAGE=php84-cli:local -t php84-fpm:local 8.4/ubuntu/fpm
```

Only images produced by `tests/smoke.sh` and scanned by `tests/audit.sh` carry validation evidence. Nothing in this repository publishes images or assigns a registry tag. Do not replace the unique validated tags with canonical or moving tags: the validation report binds the names to the image IDs and layer evidence that were checked. The FPM Dockerfile declares `ARG BASE_IMAGE` before `FROM ${BASE_IMAGE}` with no default; the shared script passes the verified unique CLI tag through `--build-arg BASE_IMAGE=<verified unique CLI tag>`. The FPM package must match the CLI core version. Build both variants together again when the PPA no longer provides the inherited CLI package version; the FPM build fails with a rebuild instruction if that exact package is unavailable.

Composer is installed from the official 2.10.3 PHAR. The build checks the pinned SHA-256 (`7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6`) before executing the PHAR, then installs it at `/usr/local/bin/composer` and records its version and checksum in build output. A Composer upgrade requires a reviewed source change to both the version and checksum; the image does not self-update or follow a moving release channel.

Ubuntu 24.04 and PPA package repositories remain mutable, so these instructions do not promise fully reproducible builds. Current validation evidence is for Linux amd64 only. Downstream application compatibility has not been verified. Previously published images are unaffected; repository changes alone do not update or secure deployed containers. This repository does not deploy images or perform live server verification.

## Use the images

Mount an application into the FPM container and connect a separate web server to FastCGI port `9000`. The pool configuration is now at `8.4/ubuntu/fpm/overrides.conf` and is copied to `/etc/php/8.4/fpm/pool.d/z-overrides.conf`. It keeps FPM in the foreground, stores its PID under `/run`, directs access and error logs to container stderr, captures worker output, preserves worker environment variables, and uses `SIGQUIT` for graceful shutdown. The FPM executable is `/usr/sbin/php-fpm8.4`. The pool listens on every interface and has no `listen.allowed_clients`, and FastCGI is unauthenticated: anyone who can reach port 9000 can run any script the container can read and can send `PHP_VALUE`/`PHP_ADMIN_VALUE` parameters. Never publish port 9000 beyond a private network shared only with the web server (the smoke test publishes it on `127.0.0.1` only).

## CI checks

The GitHub Actions workflow runs on pull requests and manual dispatch with Ubuntu 24.04 and a 45-minute timeout. It performs ShellCheck and shell/Python/workflow syntax checks, then runs the shared smoke and audit scripts without retaining image tags. It uploads `validation.json`, Trivy JSON and stderr reports, and the audit summary for 14 days; image archives are not uploaded. The job summary includes per-image scan counts, including untriaged Critical/High findings. A green CI run means the static checks, image builds, smoke checks, and audit completed with no Critical or High finding outside `tests/trivy-triaged.txt`. The allowlist records triage decisions; it does not replace independent triage of new findings. CI does not publish or deploy images.
