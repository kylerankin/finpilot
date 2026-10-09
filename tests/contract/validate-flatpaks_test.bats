#!/usr/bin/env bats
# Tests for build/validate-flatpaks.sh.
#
# All runs use a fake flatpak binary, never the host's. The contract under
# test: every line must be blank, a '#' comment, a [Flatpak Preinstall <app-id>]
# header, or a key=value pair; every such section must declare Branch=; every
# app-id is passed to `flatpak remote-info` as data, and the Branch= value
# is appended to the app ref as APP//BRANCH so a non-existent branch fails;
# and an empty discovery result fails closed instead of passing vacuously.
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
        # last arg is the app ref (APP//BRANCH); the branch is everything
        # after the final "//". A nonexistent branch is simulated via
        # MOCK_BRANCH_FAILURES.
        app="${@: -1}"
        app_id="${app%%//*}"
        branch="${app##*//}"
        case " ${MOCK_REMOTE_FAILURES:-} " in
            *" ${app_id} "*)
                echo 'error: remote-info failed' >&2
                exit 42
                ;;
        esac
        case " ${MOCK_BRANCH_FAILURES:-} " in
            *" $branch "*)
                echo 'error: No remote refs found for branch' >&2
                exit 43
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

@test "validator passes a well-formed preinstall file" {
    cat > "${FIXTURES}/base.preinstall" <<'EOF'
[Flatpak Preinstall org.gnome.Calculator]
Branch=stable
EOF
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PASS: ${FIXTURES}/base.preinstall: org.gnome.Calculator (stable)"* ]]
    [[ "${output}" == *"1 preinstall files, 1 app checks, 0 failures."* ]]
}

@test "validator fails closed on a missing Branch= key" {
    cat > "${FIXTURES}/base.preinstall" <<'EOF'
[Flatpak Preinstall org.gnome.Calculator]
[Flatpak Preinstall org.gnome.TextEditor]
Branch=stable
EOF
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"FAIL: ${FIXTURES}/base.preinstall: org.gnome.Calculator: missing Branch= key"* ]]
    # The well-formed app in the same file is still checked and reported.
    [[ "${output}" == *"PASS: ${FIXTURES}/base.preinstall: org.gnome.TextEditor (stable)"* ]]
}

@test "validator fails when an app is not on flathub" {
    export MOCK_REMOTE_FAILURES="com.example.Missing"
    cat > "${FIXTURES}/base.preinstall" <<'EOF'
[Flatpak Preinstall com.example.Missing]
Branch=stable
EOF
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"FAIL: ${FIXTURES}/base.preinstall: com.example.Missing: not on flathub (exit 42)"* ]]
}

@test "validator fails closed when the directory has no preinstall files" {
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"No .preinstall files found"* ]]
}

@test "validator fails closed when the directory does not exist" {
    run bash "${SCRIPT}" "${FIXTURES}/nope"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Flatpak directory does not exist"* ]]
}

@test "validator ensures the flathub remote and passes the branch as data" {
    cat > "${FIXTURES}/base.preinstall" <<'EOF'
[Flatpak Preinstall org.gnome.Calculator]
Branch=stable
EOF
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 0 ]
    run grep -c '^remote-add --user --if-not-exists flathub ' "${CALLS}"
    [ "${output}" = "1" ]
    run grep -c '^remote-info --user flathub org.gnome.Calculator//stable$' "${CALLS}"
    [ "${output}" = "1" ]
}

@test "validator fails when the Branch value does not exist on the remote" {
    # Regression (projectbluefin/finpilot#508): Branch= was only echoed in the
    # PASS line, so a non-empty but nonexistent branch such as Branch=nope
    # passed. remote-info is now called with --branch, so a missing branch
    # fails instead of resolving against the remote default.
    export MOCK_BRANCH_FAILURES="stable"
    cat > "${FIXTURES}/base.preinstall" <<'EOF'
[Flatpak Preinstall org.gnome.Calculator]
Branch=stable
EOF
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"FAIL: ${FIXTURES}/base.preinstall: org.gnome.Calculator: not on flathub (exit 43)"* ]]
}

@test "validator accepts blank lines and # comments" {
    cat > "${FIXTURES}/base.preinstall" <<'EOF'
# Header comment

[Flatpak Preinstall org.gnome.Calculator]
Branch=stable

# Trailing comment
EOF
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 preinstall files, 1 app checks, 0 failures."* ]]
}

@test "validator rejects a ';' comment, which flatpak parses as a syntax error" {
    # flatpak's parser is GKeyFile: ';' is not a comment character, and a
    # malformed line makes it discard the whole file while still exiting 0.
    cat > "${FIXTURES}/base.preinstall" <<'EOF'
# Header
;[Flatpak Preinstall org.gnome.Calculator]
;Branch=stable

[Flatpak Preinstall org.gnome.TextEditor]
Branch=stable
EOF
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"FAIL: ${FIXTURES}/base.preinstall:2: not a # comment"* ]]
    [[ "${output}" == *"FAIL: ${FIXTURES}/base.preinstall:3: not a # comment"* ]]
    # The well-formed section is still checked and reported.
    [[ "${output}" == *"PASS: ${FIXTURES}/base.preinstall: org.gnome.TextEditor (stable)"* ]]
    [[ "${output}" == *"1 app checks, 2 failures."* ]]
}

@test "validator rejects a group header flatpak would skip" {
    # Groups are matched by prefix and anything else is skipped at g_info level,
    # so a header with no app-id installs nothing and says nothing.
    cat > "${FIXTURES}/base.preinstall" <<'EOF'
[Flatpak Preinstall]
EOF
    run bash "${SCRIPT}" "${FIXTURES}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"FAIL: ${FIXTURES}/base.preinstall:1: not a # comment"* ]]
}
