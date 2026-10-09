#!/usr/bin/env bash
set -u
BATS_TEST_DIRNAME="/tmp/finpilot/tests/contract"
#!/usr/bin/env bats
# Tests for build/validate-flatpaks.sh.
#
# All runs use a fake flatpak binary, never the host's. The contract under
# test: every line must be blank, a '#' comment, a [Flatpak Preinstall <app-id>]
# header, or a key=value pair; every such section must declare Branch=; every
# app-id is passed to `flatpak remote-info` as data; and an empty discovery
# result fails closed instead of passing vacuously.
#
# Run with: bats tests/contract/validate-flatpaks_test.bats

SCRIPT="${BATS_TEST_DIRNAME}/../../build/validate-flatpaks.sh"

setup() {
    WORKDIR="$(mktemp -d)"
    FIXTURES="${WORKDIR}/flatpaks"
    CALLS="${WORKDIR}/calls"
    mkdir -p "${FIXTURES}" "${WORKDIR}/bin"
    : > "${CALLS}"
    cat > "${WORKDIR}/bin/flatpak" <<'MOCK'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${CALLS}"
case "$1" in
    remote-add)
        ;;
    remote-info)
        # $1=remote-info $2=--user $3=flathub $4=app-id
        [[ $# -eq 4 ]] || exit 99
        case " ${MOCK_REMOTE_FAILURES:-} " in
            *" $4 "*)
                echo 'error: remote-info failed' >&2
                exit 42
                ;;
        esac
        ;;
    *) echo "unexpected flatpak operation: $*" >&2; exit 99 ;;
esac
MOCK
    chmod +x "${WORKDIR}/bin/flatpak"
    export CALLS
    export PATH="${WORKDIR}/bin:/usr/bin:/bin"
}

teardown() {
    rm -rf "${WORKDIR}"
}

run() { output=$("$@" 2>&1); status=$?; }
pass=0; fail=0
declare -a TEST_NAMES=( "validator passes a well-formed preinstall file" "validator fails closed on a missing Branch= key" "validator fails when an app is not on flathub" "validator fails closed when the directory has no preinstall files" "validator fails closed when the directory does not exist" "validator ensures the flathub remote and passes app-ids as data" "flathub remote descriptor is pinned to its checked-in fixture SHA256" "validator accepts blank lines and # comments" "validator rejects a ';' comment, which flatpak parses as a syntax error" "validator rejects a group header flatpak would skip")
declare -a BODYFILES=(
  "/tmp/bats-pt80hd96/body.0.sh"
  "/tmp/bats-pt80hd96/body.1.sh"
  "/tmp/bats-pt80hd96/body.2.sh"
  "/tmp/bats-pt80hd96/body.3.sh"
  "/tmp/bats-pt80hd96/body.4.sh"
  "/tmp/bats-pt80hd96/body.5.sh"
  "/tmp/bats-pt80hd96/body.6.sh"
  "/tmp/bats-pt80hd96/body.7.sh"
  "/tmp/bats-pt80hd96/body.8.sh"
  "/tmp/bats-pt80hd96/body.9.sh"
)

for ((t=0; t<${#BODYFILES[@]}; t++)); do
    setup
    set +e
    source "${BODYFILES[t]}"
    __rc=$?
    set +e
    teardown
    if [ $__rc -eq 0 ]; then
        echo "ok - ${TEST_NAMES[t]}"
        pass=$((pass+1))
    else
        echo "not ok - ${TEST_NAMES[t]} (rc=$__rc)"
        fail=$((fail+1))
    fi
done
echo "$pass passed, $fail failed"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)

