#!/usr/bin/env bash
#
# secret.sh — minimal GPG-backed secret store
#
#   secret.sh set <name>       Store a secret (prompts for value, or reads stdin)
#   secret.sh get <name>       Print a secret to stdout
#   secret.sh get-many <name>...
#                              Print "<name><TAB><secret>" lines, asking for a
#                              password only once if the secrets share one
#   secret.sh list             List stored secret names
#   secret.sh delete <name>    Remove a secret
#
# Environment (all optional):
#   SECRET_DIR              Storage directory (default: ~/.secrets)
#   SECRET_PASSPHRASE_FILE  Read the passphrase from this file instead of asking
#
# Examples:
#   ./secret.sh set myapp-api-key
#   printf '%s' "sk-abc123" | ./secret.sh set myapp-api-key
#   TOKEN=$(./secret.sh get myapp-api-key)

set -euo pipefail
set +x      # never trace, even under bash -x: the trace would show the passphrase
umask 077   # new files 600, new directories 700

SECRET_DIR="${SECRET_DIR:-$HOME/.secrets}"
SECRET_PASSPHRASE_FILE="${SECRET_PASSPHRASE_FILE:-}"

die()   { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,/^$/s/^# \{0,1\}//p' "$0" >&2; exit 0; }   # prints the comment at the top
path()  { printf '%s/%s.gpg' "$SECRET_DIR" "$1"; }

require_name() {
    [[ -n "${1:-}" ]] || die "missing secret name (see: $0 --help)"
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid name '$1' (use letters, digits, . _ -)"
}
require_secret() { require_name "${1:-}"; [[ -f "$(path "$1")" ]] || die "no such secret: $1"; }

# gpg-agent is never involved: this script reads the passphrase itself and
# hands it to gpg on fd 3, so it is never on a command line (visible in ps) or
# on disk, and it works where gpg-agent can't start (network-mounted home, no
# logind session, full quota). gpg gets a throwaway home directory instead of
# your ~/.gnupg, deleted again on exit.
use_gpg() {
    command -v gpg >/dev/null 2>&1 || die "gpg not found in PATH"
    GNUPGHOME="$(mktemp -d /tmp/secret.sh.XXXXXX)"
    export GNUPGHOME
    trap 'rm -rf "$GNUPGHOME"' EXIT
}

# read_passphrase <prompt> [confirm]: sets PASSPHRASE, from SECRET_PASSPHRASE_FILE
# or from the terminal (/dev/tty, so it works while stdin carries the secret).
read_passphrase() {
    local again
    if [[ -n "$SECRET_PASSPHRASE_FILE" ]]; then
        [[ -r "$SECRET_PASSPHRASE_FILE" ]] || die "cannot read $SECRET_PASSPHRASE_FILE"
        IFS= read -r PASSPHRASE < "$SECRET_PASSPHRASE_FILE" || true
        [[ -n "$PASSPHRASE" ]] || die "empty passphrase file"
        return 0
    fi
    { : </dev/tty; } 2>/dev/null || die "no terminal for passphrase prompt; set SECRET_PASSPHRASE_FILE"
    while :; do
        printf '%s' "$1" >/dev/tty; IFS= read -rs PASSPHRASE </dev/tty; printf '\n' >/dev/tty
        [[ -n "$PASSPHRASE" ]] || die "empty passphrase"
        [[ "${2:-}" == confirm ]] || return 0
        printf 'Confirm passphrase: ' >/dev/tty; IFS= read -rs again </dev/tty; printf '\n' >/dev/tty
        [[ "$PASSPHRASE" == "$again" ]] && return 0
        printf 'Passphrases do not match, try again.\n' >/dev/tty
    done
}

# gpg with $PASSPHRASE on fd 3. --s2k-count is the strongest key stretching:
# left unset, gpg starts gpg-agent just to ask for it, and without an agent it
# falls back to a value 1000 times weaker.
gpg_pass() {
    gpg --quiet --yes --batch --pinentry-mode loopback --s2k-count 65011712 \
        --passphrase-fd 3 "$@" 3< <(printf '%s' "$PASSPHRASE")
}

decrypt() { gpg_pass --decrypt "$(path "$1")"; }   # decrypt <name>: print the secret

emit() {   # emit <name> <secret>: one "<name><TAB><secret>" line
    [[ "$2" != *[$'\n\t']* ]] || die "secret '$1' contains a newline or tab; use: get $1"
    printf '%s\t%s\n' "$1" "$2"
}

cmd_set() {
    require_name "${1:-}"
    mkdir -p "$SECRET_DIR"
    chmod 700 "$SECRET_DIR"
    local value
    if [[ -t 0 ]]; then
        printf 'Enter secret for "%s": ' "$1" >&2
        IFS= read -rs value
        printf '\n' >&2
    else
        value="$(cat)"
    fi
    [[ -n "$value" ]] || die "empty secret, nothing stored"

    read_passphrase "Passphrase for \"$1\": " confirm
    printf '%s' "$value" | gpg_pass --symmetric --cipher-algo AES256 -o "$(path "$1")"
    printf 'stored: %s\n' "$1" >&2
}

cmd_get() {
    require_secret "${1:-}"
    read_passphrase "Passphrase for \"$1\": "
    decrypt "$1"
}

cmd_get_many() {
    (( $# )) || die "missing secret name (see: $0 --help)"
    local name value list error=""
    local -a failed=()
    for name in "$@"; do require_secret "$name"; done

    # Ask once and try that passphrase on every secret. If it opens none of
    # them it was probably mistyped, so ask once more.
    list="$*"
    for _ in 1 2; do
        read_passphrase "${error}Passphrase for ${list// /, }: "
        failed=()
        for name in "$@"; do
            if value="$(decrypt "$name" 2>/dev/null)"; then
                emit "$name" "$value"
            else
                failed+=("$name")
            fi
        done
        (( ${#failed[@]} < $# )) && break
        error="Wrong passphrase. "
    done

    # Secrets with a passphrase of their own get a prompt each.
    (( ${#failed[@]} )) || return 0
    for name in "${failed[@]}"; do
        read_passphrase "Passphrase for $name: "
        value="$(decrypt "$name" 2>/dev/null)" || die "wrong passphrase for $name"
        emit "$name" "$value"
    done
}

cmd_list() {
    local f
    for f in "$SECRET_DIR"/*.gpg; do
        [[ -e "$f" ]] || break   # no matches: the pattern itself comes back
        f="${f##*/}"
        printf '%s\n' "${f%.gpg}"
    done
}

cmd_delete() {
    require_secret "${1:-}"
    rm -f -- "$(path "$1")"
    printf 'deleted: %s\n' "$1" >&2
}

case "${1:-}" in
    set)          use_gpg; shift; cmd_set "$@" ;;
    get)          use_gpg; shift; cmd_get "$@" ;;
    get-many)     use_gpg; shift; cmd_get_many "$@" ;;
    list|ls)      cmd_list ;;
    delete|rm)    shift; cmd_delete "$@" ;;
    -h|--help|"") usage ;;
    *)            die "unknown command: $1 (see: $0 --help)" ;;
esac
