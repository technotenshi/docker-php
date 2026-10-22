# Repository Guidelines

## Project Structure & Module Organization

This repository defines Ubuntu 24.04 PHP 8.4 container images. The `8.4/` directory contains `ubuntu/cli/Dockerfile` and `ubuntu/fpm/Dockerfile`; the FPM context also contains `overrides.conf` and `jit.ini`. CLI installs PHP, extensions, and pinned Composer. FPM requires an explicit matching CLI image through `BASE_IMAGE` and installs the same PHP package version. `tests/` contains the shared image smoke and vulnerability audit scripts, the FastCGI probe, and the triaged-vulnerability allowlist `trivy-triaged.txt`. `.github/workflows/php2shell.yml` runs these checks. The former `8.0/` container paths are retired.

## Build, Test, and Development Commands

Run validation from the repository root with Docker, Python 3, and Bash available. Docker must use a local Unix-socket endpoint and the default Buildx builder must use the Docker driver. Network access is required for Ubuntu/PPA packages, Composer, the Trivy scanner image, and its vulnerability database. Start with a new empty artifact directory:

```sh
ARTIFACT_DIR=$(mktemp -d)
bash tests/smoke.sh "$ARTIFACT_DIR" --keep-images
bash tests/audit.sh "$ARTIFACT_DIR"
```

The smoke script builds both images with unique tags, validates runtime/package/module behavior and live FPM behavior, then saves image archives and `validation.json`. Use the exact tags recorded in that report. On success, `--keep-images` retains the images; failed runs clean up resources they created. Without the flag, smoke validation removes its image tags after preserving the report and archives. The audit requires the smoke `validation.json` plus both image archives, verifies that scan IDs and Ubuntu package coverage match the report, and writes separate Trivy reports, stderr logs, and a summary. It refreshes and validates the vulnerability database before offline scans and treats operational failures as failures. It also fails on Critical or High findings whose IDs are not in `tests/trivy-triaged.txt`; add an ID there (reason after `#`) only after independent triage.

The shared script builds the CLI first and passes its verified unique tag as `BASE_IMAGE` to the FPM Dockerfile (`ARG BASE_IMAGE` followed by `FROM ${BASE_IMAGE}`). Build contexts are the variant directories so FPM's `COPY overrides.conf` and `COPY jit.ini` resolve. `--pull=false` alone does not prove parent identity; the script checks the captured CLI image ID before and after the FPM build and verifies the FPM root filesystem layers begin with the captured CLI layers. The FPM package must match the CLI core version; rebuild the pair if the PPA has rotated that version out.

The CI workflow runs `bash -n`, ShellCheck, a Python syntax check, workflow YAML parsing, then the smoke and audit scripts. It retains the validation report, Trivy JSON/stderr reports, and audit summary for 14 days; image archives are not uploaded. The job summary records scan counts, and a green workflow means no Critical or High finding outside `tests/trivy-triaged.txt`. Independently triage new findings; actionable in-scope Critical or High findings block repository acceptance. To run the shell checks locally:

```sh
bash -n tests/smoke.sh tests/audit.sh
shellcheck tests/smoke.sh tests/audit.sh
python3 -c 'import ast; ast.parse(open("tests/fpm-probe.py").read())'
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/php2shell.yml")'
```

## Coding Style & Naming Conventions

Follow existing Dockerfiles: uppercase instructions, one package per continuation line, eight-space package indentation, and four-space indentation for chained `&&` commands. Keep versioned package names, executable paths, and configuration destinations consistent. Use INI sections and semicolon comments in `overrides.conf`. Preserve the `<version>/ubuntu/<cli|fpm>/` layout. Shell scripts use Bash strict mode; no formatter is configured.

## Testing Guidelines

The smoke and audit scripts are the repository's validation suite. Run both for container changes and include the artifact report and audit results in the pull request. The smoke checks PHP 8.4.27 or later within the 8.4 branch, package-version consistency, Composer's pinned checksum/version, required modules, FPM configuration and executable, live FastCGI requests, environment forwarding, stream logs, and graceful shutdown. The audit uses a refreshed Trivy database and writes full JSON reports; scanner silence alone does not prove PPA packages contain a particular upstream fix. Actionable in-scope Critical or High findings block acceptance.

## Commit & Pull Request Guidelines

Recent commits use short, lowercase action summaries, such as `adding php 8.0 fpm`; no formal commit prefix convention is evident. Keep commits focused. Pull requests should explain the change, identify affected versions and variants, link relevant issues, and list build, smoke, and audit results. Explain package or base-image changes and any external repository failures encountered during validation.
