#!/usr/bin/env bash
set -Eeuo pipefail
usage() { echo "usage: bash tests/smoke.sh EMPTY_ARTIFACT_DIR [--keep-images]" >&2; exit 2; }
[[ $# == 1 || ( $# == 2 && $2 == --keep-images ) ]] || usage
artifact_dir=$1
keep_images=false
[[ ${2-} == --keep-images ]] && keep_images=true
[[ -d $artifact_dir ]] || { echo "artifact directory must already exist" >&2; exit 2; }
[[ -z $(find "$artifact_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || { echo "artifact directory must be empty" >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
run_id="php84-smoke-$(date -u +%Y%m%d%H%M%S)-$$"
cli_tag="${run_id}-cli:local"
fpm_tag="${run_id}-fpm:local"
container="${run_id}-fpm"
owned_tags=()
declare -A owned_tag_ids=()
declare -A owned_iid_files=()
owned_container=false
container_id=
preserve=false
success=false
cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [[ $status != 0 ]] && $owned_container && [[ -n $container_id ]]; then docker logs "$container_id" >&2 || true; fi
    if $owned_container && [[ -n $container_id ]]; then docker rm -f "$container_id" >/dev/null 2>&1 || true; fi
    if ! $preserve; then
        for ((index=${#owned_tags[@]}-1; index>=0; index--)); do
            tag=${owned_tags[index]}
            current_id=$(docker image inspect --format '{{.Id}}' "$tag" 2>/dev/null || true)
            owned_id=${owned_tag_ids[$tag]-}
            if [[ -z $owned_id && -s ${owned_iid_files[$tag]-} ]]; then owned_id=$(cat "${owned_iid_files[$tag]}"); fi
            if [[ -n $owned_id && $current_id == "$owned_id" ]]; then docker image rm "$tag" >/dev/null 2>&1 || true; fi
        done
    fi
    if ! $success; then rm -f "$artifact_dir/cli.tar" "$artifact_dir/fpm.tar" "$artifact_dir/validation.json"; fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT INT TERM
trap 'exit 130' INT
trap 'exit 143' TERM
negative_checks=()
verify_tag_identity() {
    local current_id
    current_id=$(docker image inspect --format '{{.Id}}' "$1")
    [[ $current_id == "$2" ]]
}
verify_layer_prefix() {
    python3 - "$1" "$2" <<'PY'
import json,sys
prefix=json.load(open(sys.argv[1])); layers=json.load(open(sys.argv[2]))[0]['RootFS']['Layers']
if layers[:len(prefix)] != prefix: raise SystemExit('FPM layers do not begin with captured CLI layers')
PY
}
for tag in "$cli_tag" "$fpm_tag"; do
    if docker image inspect "$tag" >/dev/null 2>&1; then echo "tag collision: $tag" >&2; exit 1; fi
done
builder_driver=$(docker buildx inspect default 2>/dev/null | sed -n 's/^Driver: *//p' | head -n1)
[[ $builder_driver == docker ]] || { echo "default buildx builder must use local docker driver (found: ${builder_driver:-unknown})" >&2; exit 1; }
daemon_host=${DOCKER_HOST:-$(docker context inspect "$(docker context show)" --format '{{(index .Endpoints "docker").Host}}')}
[[ $daemon_host == unix://* ]] || { echo "Docker endpoint must be a local Unix socket (found: $daemon_host)" >&2; exit 1; }
owned_tags+=("$cli_tag")
owned_iid_files[$cli_tag]="$work/cli.iid"
docker buildx build --builder default --load --iidfile "${owned_iid_files[$cli_tag]}" --pull --no-cache -t "$cli_tag" "$repo/8.4/ubuntu/cli"
cli_id=$(cat "${owned_iid_files[$cli_tag]}")
owned_tag_ids[$cli_tag]=$cli_id
if verify_tag_identity "$cli_tag" sha256:0000000000000000000000000000000000000000000000000000000000000000; then
    echo "built-image identity verifier accepted a mismatched ID" >&2; exit 1
fi
negative_checks+=("verify_tag_identity rejected a deliberately mismatched ID for the built CLI image")
docker image inspect "$cli_tag" >"$work/cli-inspect.json"
python3 - "$work/cli-inspect.json" "$work/cli-layers.json" <<'PY'
import json,sys
json.dump(json.load(open(sys.argv[1]))[0]['RootFS']['Layers'],open(sys.argv[2],'w'))
PY
cli_runtime=$(docker run --rm "$cli_id" php -r 'echo json_encode(["version"=>PHP_VERSION,"id"=>PHP_VERSION_ID,"sapi"=>PHP_SAPI,"modules"=>get_loaded_extensions()]);')
cli_packages=$(docker run --rm "$cli_id" dpkg-query -W -f='${Package}=${Version}\n' php8.4-cli php8.4-common php8.4-curl php8.4-mbstring php8.4-opcache php8.4-readline php8.4-xml php8.4-zip php8.4-xdebug)
composer_version=$(docker run --rm "$cli_id" composer --version --no-ansi)
composer_hash=$(docker run --rm "$cli_id" sha256sum /usr/local/bin/composer | awk '{print $1}')
[[ $composer_version == *'Composer version 2.10.3 '* ]] || { echo "unexpected Composer version: $composer_version" >&2; exit 1; }
[[ $composer_hash == 7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6 ]] || { echo "Composer checksum mismatch" >&2; exit 1; }
python3 - "$cli_runtime" "$cli_packages" <<'PY'
import json,sys
r=json.loads(sys.argv[1]); p=dict(x.split('=',1) for x in sys.argv[2].splitlines())
if not 80427 <= r['id'] < 80500: raise SystemExit('CLI PHP outside required 8.4.27 floor/branch')
required={'curl','mbstring','Zend OPcache','readline','xdebug','dom','SimpleXML','xml','xmlreader','xmlwriter','xsl','zip'}
missing=required-set(r['modules'])
if missing: raise SystemExit('CLI missing modules: '+', '.join(sorted(missing)))
core=['php8.4-cli','php8.4-common','php8.4-curl','php8.4-mbstring','php8.4-opcache','php8.4-readline','php8.4-xml','php8.4-zip']
if len({p[x] for x in core}) != 1: raise SystemExit('CLI core PHP package version skew')
PY
# Guard tests: extract the real RUN blocks from the Dockerfiles (each must match
# exactly one block, so renaming the matched strings breaks this) and execute
# them inside the built CLI image against stub php/dpkg-query/apt-get/php-fpm8.4
# binaries that simulate version floors, package skew, and apt failures.
mkdir "$work/guard-stubs"
cat >"$work/guard-stubs/php" <<'SH'
#!/bin/sh
if [ "${1-}" = -r ]; then
    version_id=${SMOKE_PHP_VERSION_ID}
    if [ -e /tmp/guard-stubs/apt-install-succeeded ] && [ -n "${SMOKE_PHP_VERSION_ID_AFTER_INSTALL-}" ]; then
        version_id=$SMOKE_PHP_VERSION_ID_AFTER_INSTALL
    fi
    code=$(printf '%s' "$2" | sed "s/PHP_VERSION_ID/$version_id/g; s/PHP_VERSION/'8.4.27'/g")
    exec /usr/bin/php8.4 -r "$code"
fi
exec /usr/bin/php8.4 "$@"
SH
cat >"$work/guard-stubs/dpkg-query" <<'SH'
#!/bin/sh
format=
for arg do case "$arg" in -f=*) format=${arg#-f=};; esac; done
for arg do
    case "$arg" in php8.4-*)
        version=8.4.27-1+ubuntu24.04.1+deb.sury.org+1
        if [ "${SMOKE_SKEW_PACKAGE-}" = "$arg" ]; then
            if [ "${SMOKE_SKEW_AFTER_INSTALL-}" != 1 ] || [ -e /tmp/guard-stubs/apt-install-succeeded ]; then version=8.4.26-1; fi
        fi
        if [ "$format" = '${Version}' ]; then printf '%s\n' "$version"; else printf '%s=%s\n' "$arg" "$version"; fi;;
    esac
done
SH
cat >"$work/guard-stubs/apt-get" <<'SH'
#!/bin/sh
for arg do
    if [ "$arg" = install ]; then
        touch /tmp/guard-stubs/apt-install-called
        [ "${SMOKE_APT_FAIL_INSTALL-}" != 1 ] || exit 100
        touch /tmp/guard-stubs/apt-install-succeeded
    fi
done
exit 0
SH
cat >"$work/guard-stubs/php-fpm8.4" <<'SH'
#!/bin/sh
echo "PHP ${SMOKE_FPM_VERSION-8.4.27} (fpm-fcgi) (built: smoke fixture)"
SH
chmod +x "$work/guard-stubs/"*
extract_guard() {
    python3 - "$1" "$2" <<'PY'
import sys
path,kind=sys.argv[1:]
lines=open(path).read().splitlines(); blocks=[]; i=0
while i < len(lines):
    if lines[i].startswith('RUN '):
        block=lines[i][4:]; i+=1
        while block.rstrip().endswith('\\') and i < len(lines):
            block=block.rstrip()[:-1]+' '+lines[i].strip(); i+=1
        blocks.append(block)
    else:
        i+=1
if kind=='cli': matches=[b for b in blocks if 'php8.4-cli' in b and 'PHP_VERSION_ID' in b]
else: matches=[b for b in blocks if 'php8.4-fpm=${common_version}' in b and 'PHP_VERSION_ID' in b]
if len(matches)!=1: raise SystemExit('could not isolate unique '+kind+' guard RUN')
print(matches[0])
PY
}
cli_guard=$(extract_guard "$repo/8.4/ubuntu/cli/Dockerfile" cli)
fpm_guard=$(extract_guard "$repo/8.4/ubuntu/fpm/Dockerfile" fpm)
expect_guard_reject() {
    image_id=$1; command=$2; version_id=$3; skew_package=$4; check_no_install=$5; label=$6
    rm -f "$work/guard-stubs/apt-install-called" "$work/guard-stubs/apt-install-succeeded"
    if docker run --rm -v "$work/guard-stubs:/tmp/guard-stubs" -e PATH=/tmp/guard-stubs:/usr/bin:/bin -e "SMOKE_PHP_VERSION_ID=$version_id" -e "SMOKE_PHP_VERSION_ID_AFTER_INSTALL=" -e "SMOKE_SKEW_PACKAGE=$skew_package" -e SMOKE_SKEW_AFTER_INSTALL= -e SMOKE_APT_FAIL_INSTALL= -e SMOKE_FPM_VERSION= "$image_id" sh -ec "$command" >"$work/guard-negative.log" 2>&1; then
        echo "$label guard unexpectedly accepted invalid fixture" >&2; exit 1
    fi
    grep -q 'ERROR:' "$work/guard-negative.log" || { echo "$label guard produced no expected diagnostic" >&2; cat "$work/guard-negative.log" >&2; exit 1; }
    if [[ $check_no_install == true ]]; then
        [[ ! -e $work/guard-stubs/apt-install-called ]] || { echo "$label guard reached apt install before rejection" >&2; exit 1; }
    fi
    negative_checks+=("$label guard rejected controlled invalid fixture")
}
expect_guard_reject "$cli_id" "$cli_guard" 80426 '' false 'CLI PHP floor'
expect_guard_reject "$cli_id" "$cli_guard" 80500 '' false 'CLI wrong PHP branch'
expect_guard_reject "$cli_id" "$cli_guard" 80427 php8.4-zip false 'CLI package skew'
expect_guard_reject "$cli_id" "$fpm_guard" 80426 '' true 'FPM inherited PHP floor'
expect_guard_reject "$cli_id" "$fpm_guard" 80500 '' true 'FPM inherited wrong PHP branch'
expect_guard_reject "$cli_id" "$fpm_guard" 80427 php8.4-zip true 'FPM inherited package skew'
expect_fpm_install_guard_reject() {
    scenario=$1; skew_package=$2; post_version_id=$3; fpm_version=$4; fail_install=$5; expected_error=$6
    rm -f "$work/guard-stubs/apt-install-called" "$work/guard-stubs/apt-install-succeeded"
    if docker run --rm -v "$work/guard-stubs:/tmp/guard-stubs" \
        -e PATH=/tmp/guard-stubs:/usr/bin:/bin \
        -e SMOKE_PHP_VERSION_ID=80427 \
        -e "SMOKE_PHP_VERSION_ID_AFTER_INSTALL=$post_version_id" \
        -e "SMOKE_SKEW_PACKAGE=$skew_package" -e SMOKE_SKEW_AFTER_INSTALL=1 \
        -e "SMOKE_APT_FAIL_INSTALL=$fail_install" -e "SMOKE_FPM_VERSION=$fpm_version" \
        "$cli_id" sh -ec "$fpm_guard" >"$work/fpm-post-install-negative.log" 2>&1; then
        echo "$scenario FPM guard unexpectedly accepted its fixture" >&2; exit 1
    fi
    grep -Fq "$expected_error" "$work/fpm-post-install-negative.log" || {
        echo "$scenario FPM guard failed for an unexpected reason" >&2
        cat "$work/fpm-post-install-negative.log" >&2
        exit 1
    }
    [[ -e $work/guard-stubs/apt-install-called ]] || { echo "$scenario never attempted FPM installation" >&2; exit 1; }
    if [[ $fail_install == 1 ]]; then
        [[ ! -e $work/guard-stubs/apt-install-succeeded ]] || { echo "$scenario unexpectedly installed FPM" >&2; exit 1; }
    else
        [[ -e $work/guard-stubs/apt-install-succeeded ]] || { echo "$scenario did not reach post-install validation" >&2; exit 1; }
    fi
    negative_checks+=("FPM guard $scenario rejected after the expected installation phase")
}
expect_fpm_install_guard_reject 'unavailable exact FPM package' '' '' 8.4.27 1 'ERROR: php8.4-fpm 8.4.27-1+ubuntu24.04.1+deb.sury.org+1 is unavailable'
expect_fpm_install_guard_reject 'post-install core package skew' php8.4-zip '' 8.4.27 0 'ERROR: php8.4-zip version'
expect_fpm_install_guard_reject 'post-install FPM package skew' php8.4-fpm '' 8.4.27 0 'ERROR: php8.4-fpm version'
expect_fpm_install_guard_reject 'FPM versus CLI runtime mismatch' '' '' 8.4.28 0 'ERROR: php-fpm8.4 runtime 8.4.28 does not match CLI runtime 8.4.27'
expect_fpm_install_guard_reject 'post-install PHP floor failure' '' 80426 8.4.27 0 'ERROR: PHP runtime must be'
expect_fpm_install_guard_reject 'post-install wrong PHP branch' '' 80500 8.4.27 0 'ERROR: PHP runtime must be'
grep -Fxq 'ARG BASE_IMAGE' "$repo/8.4/ubuntu/fpm/Dockerfile" || { echo "FPM BASE_IMAGE ARG must have no default" >&2; exit 1; }
if docker buildx build --builder default --pull=false --no-cache -f "$repo/8.4/ubuntu/fpm/Dockerfile" "$repo/8.4/ubuntu/fpm" >"$work/missing-parent.log" 2>&1; then
    echo "FPM build unexpectedly accepted missing BASE_IMAGE" >&2; exit 1
fi
grep -Eiq 'base name .*should not be blank|invalid reference format' "$work/missing-parent.log" || { echo "missing BASE_IMAGE failed for an unexpected reason" >&2; cat "$work/missing-parent.log" >&2; exit 1; }
if grep -Eq '\[[0-9]+/[0-9]+\] RUN ' "$work/missing-parent.log"; then echo "missing BASE_IMAGE reached a RUN step" >&2; exit 1; fi
if docker buildx build --builder default --pull=false --no-cache --build-arg BASE_IMAGE= -f "$repo/8.4/ubuntu/fpm/Dockerfile" "$repo/8.4/ubuntu/fpm" >"$work/empty-parent.log" 2>&1; then
    echo "FPM build unexpectedly accepted empty BASE_IMAGE" >&2; exit 1
fi
grep -Eiq 'base name .*should not be blank|invalid reference format' "$work/empty-parent.log" || { echo "empty BASE_IMAGE failed for an unexpected reason" >&2; cat "$work/empty-parent.log" >&2; exit 1; }
if grep -Eq '\[[0-9]+/[0-9]+\] RUN ' "$work/empty-parent.log"; then echo "empty BASE_IMAGE reached a RUN step" >&2; exit 1; fi
negative_checks+=("missing and empty BASE_IMAGE builds rejected")
mkdir "$work/negative"
printf '%s\n' "<?php file_put_contents('/tmp/negative/exploit-marker', 'ran');" >"$work/negative/composer.phar"
cat >"$work/negative/curl" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; cp /tmp/negative/composer.phar "$1"; exit 0; fi
    shift
done
exit 2
SH
cat >"$work/negative/php" <<'SH'
#!/bin/sh
touch /tmp/negative/php-was-run
exit 0
SH
chmod +x "$work/negative/curl" "$work/negative/php"
composer_run=$(python3 - "$repo/8.4/ubuntu/cli/Dockerfile" <<'PY'
import sys
lines=open(sys.argv[1]).read().splitlines(); blocks=[]; i=0
while i < len(lines):
    if lines[i].startswith('RUN '):
        block=lines[i][4:]; i+=1
        while block.rstrip().endswith('\\') and i < len(lines):
            block=block.rstrip()[:-1]+' '+lines[i].strip(); i+=1
        blocks.append(block)
    else:
        i+=1
matches=[b for b in blocks if 'composer_tmp=' in b]
if len(matches)!=1: raise SystemExit('could not isolate unique Composer RUN block')
print(matches[0])
PY
)
if docker run --rm -v "$work/negative:/tmp/negative" -e PATH=/tmp/negative:/usr/bin:/bin "$cli_id" sh -c "$composer_run" >"$work/composer-negative.log" 2>&1; then
    echo "Composer checksum negative check unexpectedly succeeded" >&2; exit 1
fi
grep -Eiq 'FAILED|checksum|computed checksum did NOT match' "$work/composer-negative.log" || { echo "Composer negative run failed for an unexpected reason" >&2; cat "$work/composer-negative.log" >&2; exit 1; }
[[ ! -e $work/negative/php-was-run ]] || { echo "Composer PHP execution occurred before checksum rejection" >&2; exit 1; }
negative_checks+=("actual Composer RUN block rejected bad checksum before PHP execution")
verify_tag_identity "$cli_tag" "$cli_id" || { echo "CLI tag identity changed before FPM build" >&2; exit 1; }
owned_tags+=("$fpm_tag")
owned_iid_files[$fpm_tag]="$work/fpm.iid"
docker buildx build --builder default --load --iidfile "${owned_iid_files[$fpm_tag]}" --pull=false --no-cache --build-arg "BASE_IMAGE=$cli_tag" -t "$fpm_tag" "$repo/8.4/ubuntu/fpm"
fpm_id=$(cat "${owned_iid_files[$fpm_tag]}")
owned_tag_ids[$fpm_tag]=$fpm_id
verify_tag_identity "$cli_tag" "$cli_id" || { echo "CLI tag identity changed during FPM build" >&2; exit 1; }
docker image inspect "$fpm_tag" >"$work/fpm-inspect.json"
python3 - "$work/fpm-inspect.json" <<'PY'
import json,sys
cmd=json.load(open(sys.argv[1]))[0]['Config']['Cmd']
if cmd != ['/usr/sbin/php-fpm8.4','-O']:
    raise SystemExit('FPM image default command is not the expected foreground command: '+repr(cmd))
PY
verify_layer_prefix "$work/cli-layers.json" "$work/fpm-inspect.json"
python3 - "$work/negative-cli-layers.json" "$work/negative-fpm-inspect.json" <<'PY'
import json,sys
json.dump(['sha256:captured'],open(sys.argv[1],'w'))
json.dump([{'RootFS':{'Layers':['sha256:wrong','sha256:new']}}],open(sys.argv[2],'w'))
PY
if verify_layer_prefix "$work/negative-cli-layers.json" "$work/negative-fpm-inspect.json" >/dev/null 2>&1; then
    echo "layer-prefix negative check accepted mismatch" >&2; exit 1
fi
negative_checks+=("rootfs layer-prefix verifier rejected mismatch")
fpm_runtime=$(docker run --rm "$fpm_id" php -r 'echo json_encode(["version"=>PHP_VERSION,"id"=>PHP_VERSION_ID,"sapi"=>PHP_SAPI,"modules"=>get_loaded_extensions()]);')
fpm_packages=$(docker run --rm "$fpm_id" dpkg-query -W -f='${Package}=${Version}\n' php8.4-cli php8.4-common php8.4-curl php8.4-mbstring php8.4-opcache php8.4-readline php8.4-xml php8.4-zip php8.4-fpm php8.4-xdebug)
docker run --rm "$fpm_id" php-fpm8.4 -t
docker run --rm "$fpm_id" php-fpm8.4 -v
python3 - "$cli_runtime" "$fpm_runtime" "$cli_packages" "$fpm_packages" <<'PY'
import json,sys
cli,fpm=map(json.loads,sys.argv[1:3]); cp=dict(x.split('=',1) for x in sys.argv[3].splitlines()); fp=dict(x.split('=',1) for x in sys.argv[4].splitlines())
for label,r in [('CLI',cli),('FPM',fpm)]:
 if not 80427 <= r['id'] < 80500: raise SystemExit(label+' PHP outside required 8.4.27 floor/branch')
 if r['sapi'] != 'cli': raise SystemExit(label+' invocation did not use cli SAPI')
expected={'curl','mbstring','Zend OPcache','readline','xdebug','dom','SimpleXML','xml','xmlreader','xmlwriter','xsl','zip'}
for label,r in [('CLI',cli),('FPM',fpm)]:
 missing=expected-set(r['modules'])
 if missing: raise SystemExit(label+' missing modules: '+', '.join(sorted(missing)))
core=['php8.4-cli','php8.4-common','php8.4-curl','php8.4-mbstring','php8.4-opcache','php8.4-readline','php8.4-xml','php8.4-zip']
if len({cp[p] for p in core}) != 1: raise SystemExit('CLI core PHP package version skew')
def inherited_packages_match(cli_pkgs, fpm_pkgs):
 return all(fpm_pkgs[p] == cli_pkgs[p] for p in core) and fpm_pkgs['php8.4-fpm'] == cli_pkgs['php8.4-common']
if not inherited_packages_match(cp,fp): raise SystemExit('FPM inherited/core package version skew')
if cli['version'] != fpm['version']: raise SystemExit('CLI and FPM runtimes differ')
PY
fixture="$work/fixture"; mkdir "$fixture"; chmod 755 "$fixture"
cat >"$fixture/index.php" <<'PHP'
<?php
header('Content-Type: text/plain');
echo 'PHP_VERSION=' . PHP_VERSION . "\n";
echo 'PHP_SAPI=' . PHP_SAPI . "\n";
echo 'MODULES=' . implode(',', get_loaded_extensions()) . "\n";
echo 'TOKEN=' . getenv('SMOKE_TOKEN') . "\n";
error_log('SMOKE_ERROR_MARKER=' . getenv('SMOKE_TOKEN'));
PHP
chmod 644 "$fixture/index.php"
token="${run_id}-token"
if docker container inspect "$container" >/dev/null 2>&1; then echo "container name collision: $container" >&2; exit 1; fi
container_id=$(docker run -d --name "$container" -e "SMOKE_TOKEN=$token" -v "$fixture:/var/www/html:ro" -p 127.0.0.1::9000 "$fpm_id")
owned_container=true
docker exec "$container_id" sh -c 'test -d /run && test -f /etc/php/8.4/fpm/pool.d/z-overrides.conf'
docker exec "$container_id" sh -c 'readlink -f /proc/1/exe' >"$work/pid1-exe.txt"
[[ $(cat "$work/pid1-exe.txt") == /usr/sbin/php-fpm8.4 ]] || { echo "FPM executable is not PID 1" >&2; exit 1; }
docker exec "$container_id" sh -c 'tr "\000" " " </proc/1/cmdline' >"$work/pid1.txt"
if ! grep -q 'php-fpm: master process' "$work/pid1.txt" || ! grep -q '/etc/php/8.4/fpm/php-fpm.conf' "$work/pid1.txt"; then
    echo "FPM master process or config path missing from PID 1" >&2; exit 1
fi
[[ $(docker image inspect --format '{{.Config.StopSignal}}' "$fpm_id") == SIGQUIT ]] || { echo "FPM image StopSignal is not SIGQUIT" >&2; exit 1; }
port=$(docker port "$container_id" 9000/tcp | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n1)
[[ $port =~ ^[0-9]+$ ]] || { echo "could not determine published FPM port" >&2; exit 1; }
ready=false
for _ in $(seq 1 50); do
 if python3 - "$port" <<'PY' >/dev/null 2>&1
import socket,sys
with socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=.2): pass
PY
 then ready=true; break; fi
 sleep .2
done
$ready || { docker logs "$container" >&2; echo "FPM did not become ready" >&2; exit 1; }
expected_php=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["version"])' "$cli_runtime")
python3 "$repo/tests/fpm-probe.py" 127.0.0.1 "$port" "$token" "$expected_php" | tee "$work/fpm-probe.log"
docker kill --signal=QUIT "$container_id" >/dev/null
for _ in $(seq 1 50); do
 [[ $(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true) != true ]] && break
 sleep .2
done
[[ $(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true) != true ]] || { echo "FPM did not stop after SIGQUIT" >&2; exit 1; }
fpm_exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container_id")
[[ $fpm_exit_code == 0 ]] || { echo "FPM exited unsuccessfully (exit code $fpm_exit_code)" >&2; exit 1; }
docker logs "$container_id" >"$work/fpm.stdout.log" 2>"$work/fpm.stderr.log"
grep -q 'GET /index.php' "$work/fpm.stderr.log" || { echo "FPM access log missing from stderr stream" >&2; cat "$work/fpm.stderr.log" >&2; exit 1; }
grep -q "SMOKE_ERROR_MARKER=$token" "$work/fpm.stderr.log" || { echo "FPM worker error log missing from stderr stream" >&2; cat "$work/fpm.stderr.log" >&2; exit 1; }
! grep -q 'JIT is incompatible' "$work/fpm.stderr.log" || { echo "FPM startup logged the Xdebug/JIT warning" >&2; cat "$work/fpm.stderr.log" >&2; exit 1; }
grep -Eiq 'ready to handle connections|fpm is running' "$work/fpm.stderr.log" || { echo "FPM startup log missing" >&2; exit 1; }
grep -Eiq 'terminating|exiting' "$work/fpm.stderr.log" || { echo "FPM graceful shutdown log missing" >&2; exit 1; }
docker rm "$container_id" >/dev/null; owned_container=false; container_id=
docker image save -o "$artifact_dir/cli.tar" "$cli_id"
docker image save -o "$artifact_dir/fpm.tar" "$fpm_id"
negative_report=$(printf '%s\n' "${negative_checks[@]}")
python3 - "$artifact_dir/validation.json" "$cli_id" "$fpm_id" "$cli_tag" "$fpm_tag" "$cli_runtime" "$fpm_runtime" "$cli_packages" "$fpm_packages" "$composer_version" "$composer_hash" "$work/cli-layers.json" "$work/fpm-inspect.json" "$keep_images" "$work/pid1.txt" "$work/fpm.stderr.log" "$negative_report" "$work/fpm-probe.log" "$fpm_exit_code" <<'PY'
import json,sys
p,ci,fi,ct,ft,cr,fr,cp,fp,cv,ch,lf,ff,keep,pidfile,logfile,negatives,probelog,exit_code=sys.argv[1:]
cl=json.load(open(lf)); fl=json.load(open(ff))[0]['RootFS']['Layers']
pkgs=lambda s: dict(x.split('=',1) for x in s.splitlines())
loglines=open(logfile).read().splitlines()
evidence=[line for line in loglines if any(needle in line.lower() for needle in ('get /index.php','smoke_error_marker=','ready to handle connections','fpm is running','terminating','exiting'))]
d={'php_version':json.loads(cr)['version'],'cli':{'tag':ct,'id':ci,'runtime':json.loads(cr),'packages':pkgs(cp),'layers':cl},'fpm':{'tag':ft,'id':fi,'php_binary_runtime':json.loads(fr),'packages':pkgs(fp),'layers':fl},'composer':{'version':cv.split()[2],'reported':cv.strip(),'sha256':ch},'fpm_layers_prefix_matches_cli':fl[:len(cl)]==cl,'fpm_runtime_evidence':{'pid1_command':open(pidfile).read().strip(),'graceful_sigquit':True,'exit_code':int(exit_code),'probe_requests':open(probelog).read().splitlines(),'logs_stderr':evidence},'negative_checks':negatives.splitlines(), 'images_retained':keep=='true','retained_images':[{'tag':ct,'id':ci},{'tag':ft,'id':fi}] if keep=='true' else []}
json.dump(d,open(p,'w'),indent=2); open(p,'a').write('\n')
PY
preserve=$keep_images
success=true
echo "Smoke validation passed. Report: $artifact_dir/validation.json"
if $keep_images; then echo "Retained images: $cli_tag ($cli_id), $fpm_tag ($fpm_id)"; fi
