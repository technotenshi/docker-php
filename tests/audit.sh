#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "usage: bash tests/audit.sh ARTIFACT_DIR" >&2; exit 2; }
[[ $# == 1 ]] || usage
artifact_dir=$1
[[ -d $artifact_dir ]] || { echo "artifact directory must already exist" >&2; exit 2; }
artifact_dir=$(cd "$artifact_dir" && pwd)
for archive in cli.tar fpm.tar; do
    [[ -s $artifact_dir/$archive ]] || { echo "required image archive is missing or empty: $artifact_dir/$archive" >&2; exit 2; }
done
[[ -s $artifact_dir/validation.json ]] || { echo "required smoke validation report is missing or empty: $artifact_dir/validation.json" >&2; exit 2; }
for report in cli-trivy.json fpm-trivy.json cli-trivy.stderr.log fpm-trivy.stderr.log audit-summary.json; do
    [[ ! -e $artifact_dir/$report && ! -L $artifact_dir/$report ]] || { echo "refusing to overwrite existing audit output: $artifact_dir/$report" >&2; exit 2; }
done

trivy_image='aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c'
daemon_host=${DOCKER_HOST:-$(docker context inspect "$(docker context show)" --format '{{(index .Endpoints "docker").Host}}')}
[[ $daemon_host == unix://* ]] || { echo "Docker endpoint must be a local Unix socket (found: $daemon_host)" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/php84-audit.XXXXXXXX")
cache_dir=$work/cache
mkdir "$cache_dir"
cleanup() {
    for cid_file in "$work"/*.cid; do
        [[ -s $cid_file ]] || continue
        docker rm -f "$(cat "$cid_file")" >/dev/null 2>&1 || true
    done
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Pulling pinned Trivy scanner and refreshing its vulnerability database..."
if ! docker run --rm --cidfile "$work/db.cid" --pull=always --user "$(id -u):$(id -g)" -v "$cache_dir:/cache" "$trivy_image" image --cache-dir /cache --scanners vuln --download-db-only >"$work/db-refresh.log" 2>&1; then
    echo "Trivy database refresh failed; audit cannot establish current vulnerability evidence." >&2
    cat "$work/db-refresh.log" >&2
    exit 1
fi
db_metadata=$cache_dir/db/metadata.json
[[ -s $db_metadata ]] || { echo "Trivy database refresh completed without database metadata; audit failed." >&2; exit 1; }
python3 - "$db_metadata" <<'PY'
import datetime,json,sys
try:
    d=json.load(open(sys.argv[1]))
    if not isinstance(d,dict) or not d:
        raise ValueError('empty metadata')
    def timestamp(key):
        value=d.get(key)
        if not isinstance(value,str):
            raise ValueError('missing '+key+' timestamp')
        return datetime.datetime.fromisoformat(value.replace('Z','+00:00'))
    now=datetime.datetime.now(datetime.timezone.utc)
    updated=timestamp('UpdatedAt'); next_update=timestamp('NextUpdate')
    if updated.tzinfo is None or next_update.tzinfo is None:
        raise ValueError('database timestamps must include a timezone')
    if updated > now+datetime.timedelta(minutes=5):
        raise ValueError('database UpdatedAt is more than five minutes in the future')
    if next_update < now:
        raise ValueError('database NextUpdate has passed; refreshed database is expired')
except Exception as e:
    raise SystemExit('invalid Trivy vulnerability database metadata: '+str(e))
PY

scan_archive() {
    local name=$1 archive=$2 temp=$work/$1-trivy.json stderr_file=$work/$1-trivy.stderr.log
    echo "Scanning $archive with the refreshed database..."
    if ! docker run --rm --cidfile "$work/$name.cid" --pull=never --network none \
        -v "$artifact_dir/$archive:/input/image.tar:ro" \
        --user "$(id -u):$(id -g)" \
        -v "$cache_dir:/cache" \
        "$trivy_image" image --cache-dir /cache --scanners vuln --skip-db-update --offline-scan --input /input/image.tar --format json \
        >"$temp" 2>"$stderr_file"; then
        echo "Trivy scan failed operationally for $archive; no clean result can be claimed." >&2
        cat "$stderr_file" >&2
        exit 1
    fi
    if ! python3 - "$temp" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    if not isinstance(d,dict) or not isinstance(d.get('Results'),list):
        raise ValueError('missing or invalid Results array')
    if not isinstance(d.get('Metadata'),dict):
        raise ValueError('missing image Metadata')
    errors=[e for r in d['Results'] if isinstance(r,dict) for e in r.get('Errors',[]) or []]
    if errors:
        raise ValueError('scanner reported errors: '+'; '.join(map(str,errors)))
except Exception as e:
    raise SystemExit('invalid or incomplete Trivy JSON for '+sys.argv[1]+': '+str(e))
PY
    then
        echo "Trivy returned invalid or incomplete JSON for $archive; audit failed." >&2
        exit 1
    fi
}

scan_archive cli cli.tar
scan_archive fpm fpm.tar

summary_tmp=$work/audit-summary.json.tmp
python3 - "$work/cli-trivy.json" "$work/fpm-trivy.json" "$db_metadata" "$trivy_image" "$artifact_dir/validation.json" >"$summary_tmp" <<'PY'
import datetime,json,sys
validation=json.load(open(sys.argv[5]))
reports=[]
for variant,path,package in (('cli',sys.argv[1],'php8.4-cli'),('fpm',sys.argv[2],'php8.4-fpm')):
    report=json.load(open(path)); counts={s:0 for s in ('CRITICAL','HIGH')}; findings=[]
    metadata=report['Metadata']
    expected_id=validation.get(variant,{}).get('id')
    if not expected_id or metadata.get('ImageID') != expected_id:
        raise SystemExit(variant+' Trivy image ID does not match validation.json')
    os_info=metadata.get('OS') or {}
    if os_info.get('Family') != 'ubuntu' or os_info.get('Name') != '24.04':
        raise SystemExit(variant+' scan did not identify Ubuntu 24.04')
    os_results=[r for r in report['Results'] if isinstance(r,dict) and r.get('Class')=='os-pkgs' and r.get('Type')=='ubuntu']
    packages=[p for r in os_results for p in (r.get('Packages') or []) if isinstance(p,dict)]
    package_names={p.get('Name') for p in packages}
    if not packages or 'php8.4-common' not in package_names or package not in package_names:
        raise SystemExit(variant+' scan has missing/incomplete Ubuntu OS package inventory')
    for result in report.get('Results',[]):
        for vulnerability in result.get('Vulnerabilities',[]) or []:
            severity=str(vulnerability.get('Severity','UNKNOWN')).upper()
            if severity in counts: counts[severity]+=1
            if severity in counts:
                findings.append({'severity':severity,'id':vulnerability.get('VulnerabilityID'),
                    'package':vulnerability.get('PkgName'),'installed_version':vulnerability.get('InstalledVersion'),
                    'fixed_version':vulnerability.get('FixedVersion'),'title':vulnerability.get('Title')})
    reports.append({'variant':variant,'image_id':expected_id,'os':'ubuntu 24.04','os_package_count':len(packages),
        'critical':counts['CRITICAL'],'high':counts['HIGH'],
        'critical_high_findings':findings,'triage_status':'pending_independent_triage'})
db=json.load(open(sys.argv[3]))
json.dump({'scanner_image':sys.argv[4],'audit_time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'database_metadata':db,'reports':reports,
    'acceptance':'pending independent triage; actionable in-scope Critical/High findings block acceptance',
    'scope_note':'Scanner silence is not proof that Ubuntu PPA packages contain target fixes; verify runtime/package versions against upstream advisories.'},sys.stdout,indent=2)
sys.stdout.write('\n')
PY
python3 -m json.tool "$summary_tmp" >/dev/null || { echo "could not validate generated audit summary" >&2; exit 1; }
python3 - "$summary_tmp" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for r in d['reports']:
    print(f"{r['variant'].upper()}: Critical={r['critical']} High={r['high']} packages={r['os_package_count']} (independent triage pending)")
print('Scanner findings require independent triage; actionable in-scope Critical/High findings block acceptance.')
PY
mv "$work/cli-trivy.json" "$artifact_dir/cli-trivy.json"
mv "$work/cli-trivy.stderr.log" "$artifact_dir/cli-trivy.stderr.log"
mv "$work/fpm-trivy.json" "$artifact_dir/fpm-trivy.json"
mv "$work/fpm-trivy.stderr.log" "$artifact_dir/fpm-trivy.stderr.log"
mv "$summary_tmp" "$artifact_dir/audit-summary.json"
echo "Trivy reports: $artifact_dir/cli-trivy.json, $artifact_dir/fpm-trivy.json"
echo "Audit summary: $artifact_dir/audit-summary.json"
