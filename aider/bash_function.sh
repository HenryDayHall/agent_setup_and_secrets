#!/usr/bin/env bash
# =============================================================================
# bash_function.sh -- run aider against the DESY Assistant, Blablador and Claude
#
# Source this file (e.g. from ~/.bashrc). It defines a shell function called
# `aider` that takes exactly the same flags as aider itself, and quietly:
#
#   * unlocks the API keys (via secret.sh) for the services your models use,
#     and hands them to aider as environment variables, never as flags;
#   * points each service at its own API endpoint, so DESY, Blablador and
#     Claude models can all be mixed in one session;
#   * adds an alias for every known model, so `--model reasoning`,
#     `--model huge` or `/model claude-opus-4-8` all work;
#   * picks repo-map and chat-history sizes suited to the main model's service
#     (override them with aider's normal --map-tokens etc.);
#   * refreshes the list of available models at most once a day.
#
# Tab completion covers every aider flag, plus model names after --model,
# --editor-model and --weak-model.
#
# `command aider ...` bypasses all of this and runs plain aider.
#
# Other commands:
#   list_models [service...]     list the models each service offers
#   refresh_models [service...]  fetch the model lists now
#
# Optional environment variables:
#   DESY_AIDER_CACHE   where refreshed model lists live
#                      (default: ~/.cache/desy_aider)
#   AIDER_DEV_REPO     run aider from this source checkout instead of the
#                      installed one
# =============================================================================

_da_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_da_seed_dir="$_da_script_dir/service_descriptions"
_da_cache_dir="${DESY_AIDER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/desy_aider}"
_da_services=(desy blablador claude)

# ---------------------------------------------------------------------------
# Per-service facts. To add a service, extend each of these.
# ---------------------------------------------------------------------------
_da_url() {
    case "$1" in
        desy)      echo "https://assistant.desy.de/api/" ;;
        blablador) echo "https://api.helmholtz-blablador.fz-juelich.de/v1/" ;;
        claude)    echo "https://api.anthropic.com/v1/" ;;
        *) return 1 ;;
    esac
}

# litellm provider prefix; each provider reads its own key/base variables
_da_prefix() {
    case "$1" in
        desy)      echo "openai/" ;;
        blablador) echo "hosted_vllm/" ;;
        claude)    echo "anthropic/" ;;
        *) return 1 ;;
    esac
}

_da_key_var() {
    case "$1" in
        desy)      echo "OPENAI_API_KEY" ;;
        blablador) echo "HOSTED_VLLM_API_KEY" ;;
        claude)    echo "ANTHROPIC_API_KEY" ;;
        *) return 1 ;;
    esac
}

_da_base_var() {
    case "$1" in
        desy)      echo "OPENAI_API_BASE" ;;
        blablador) echo "HOSTED_VLLM_API_BASE" ;;
        claude)    return 1 ;;  # litellm already knows Anthropic's endpoint
        *) return 1 ;;
    esac
}

# Repo-map / chat-history scale (0-10) used when this service runs the main
# model. Smaller for services with smaller or slower models.
_da_scale() {
    case "$1" in
        blablador) echo 1 ;;
        desy)      echo 2 ;;
        claude)    echo 4 ;;
        *)         echo 2 ;;
    esac
}

# ---------------------------------------------------------------------------
# Model lists
# ---------------------------------------------------------------------------

# Path of the model list to use: the refreshed one in the cache if present,
# otherwise the newest copy shipped in service_descriptions/.
_da_description_file() {
    local service="$1"
    if [[ -s "$_da_cache_dir/$service.json" ]]; then
        echo "$_da_cache_dir/$service.json"
        return 0
    fi
    # Globs expand in sorted order, and the names end in a date, so the last
    # match is the newest.
    local files=("$_da_seed_dir/${service}"_*.json)
    [[ -e "${files[-1]}" ]] || return 1
    echo "${files[-1]}"
}

# Model ids exactly as the service reports them, one per line.
_da_model_ids() {
    local file
    file=$(_da_description_file "$1") || return 1
    python3 -I - "$file" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f).get("data", [])
except (OSError, ValueError, AttributeError):
    sys.exit(1)
for item in data:
    if isinstance(item, dict) and item.get("id"):
        print(item["id"])
PY
}

# Lines of "<short name> <full aider model name>" for one service. Blablador
# only exposes its stable "alias-*" models, without the "alias-" prefix.
_da_model_table() {
    local service="$1" prefix id
    prefix=$(_da_prefix "$service") || return 1
    while IFS= read -r id; do
        case "$service" in
            blablador)
                [[ "$id" == alias-* ]] || continue
                echo "${id#alias-} ${prefix}${id}" ;;
            *)
                [[ "$id" == *" "* ]] && continue
                echo "${id} ${prefix}${id}" ;;
        esac
    done < <(_da_model_ids "$service" 2>/dev/null)
}

# Lines of "<service> <short name> <full name>" for every known model.
_da_all_models() {
    local service short full
    for service in "${_da_services[@]}"; do
        while read -r short full; do
            echo "$service $short $full"
        done < <(_da_model_table "$service")
    done
}

# Every short model name, for tab completion.
_da_short_names() {
    _da_all_models | cut -d' ' -f2
}

# _da_service_of <name> <table from _da_all_models>
# Which service does a model name (short or full) belong to?
_da_service_of() {
    local name="$1" table="$2" service short full
    for service in "${_da_services[@]}"; do
        [[ "$name" == "$(_da_prefix "$service")"* ]] && { echo "$service"; return 0; }
    done
    while read -r service short full; do
        [[ "$name" == "$short" ]] && { echo "$service"; return 0; }
    done <<< "$table"
    [[ "${name,,}" == *claude* ]] && { echo claude; return 0; }
    return 1
}

list_models() {
    local services=("$@") service short full
    (( ${#services[@]} )) || services=("${_da_services[@]}")
    for service in "${services[@]}"; do
        echo "$service  ($(_da_description_file "$service" 2>/dev/null || echo 'no list'))"
        while read -r short full; do
            printf '  %-28s %s\n' "$short" "$full"
        done < <(_da_model_table "$service")
    done
}

# ---------------------------------------------------------------------------
# Refreshing model lists
# ---------------------------------------------------------------------------

# _da_fetch_models <service> <key>
# Fetches the service's /models list and stores it in the cache if it is a
# real model list (error replies are discarded). Reports added/removed models.
_da_fetch_models() {
    local service="$1" key="$2" url header tmp
    local -a extra=()
    url="$(_da_url "$service")models" || return 1
    case "$service" in
        claude) header="x-api-key: $key"; extra=(-H "anthropic-version: 2023-06-01") ;;
        *)      header="Authorization: Bearer $key" ;;
    esac
    mkdir -p "$_da_cache_dir" || return 1
    tmp=$(mktemp "$_da_cache_dir/.$service.XXXXXX") || return 1

    # The auth header goes in on stdin, so the key never appears in curl's
    # command line (which any user on the machine can read with `ps`).
    if ! printf '%s\n' "$header" | curl -sS --fail --max-time 5 \
            -H @- "${extra[@]}" \
            -o "$tmp" "$url" 2>/dev/null; then
        rm -f "$tmp"
        echo "Note: could not refresh the $service model list (offline or off-VPN?)." >&2
        return 1
    fi

    local old_file
    old_file=$(_da_description_file "$service" 2>/dev/null)
    if ! python3 -I - "$tmp" "$_da_cache_dir/$service.json" "$service" "$old_file" <<'PY'
import json, os, sys
new_path, dest, service, old_path = sys.argv[1:5]
try:
    with open(new_path) as f:
        new = json.load(f)
    ids = {m["id"] for m in new["data"]}
    assert ids
except Exception:
    sys.exit(1)  # not a model list (e.g. "session expired"): keep the old one
old_ids = set()
if old_path:
    try:
        with open(old_path) as f:
            old_ids = {m["id"] for m in json.load(f)["data"]}
    except Exception:
        pass
with open(dest + ".tmp", "w") as f:
    json.dump(new, f, indent=4)
os.replace(dest + ".tmp", dest)
added, removed = sorted(ids - old_ids), sorted(old_ids - ids)
if old_ids and (added or removed):
    print(f"The {service} model list changed:")
    for m in added:
        print(f"  + {m}")
    for m in removed:
        print(f"  - {m}")
PY
    then
        echo "Note: $service returned something that isn't a model list; kept the old one." >&2
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

# True if the cached list for this service is missing or over a day old.
_da_is_stale() {
    local file="$_da_cache_dir/$1.json"
    [[ ! -s "$file" ]] || [[ -n "$(find "$file" -mmin +1440 2>/dev/null)" ]]
}

refresh_models() {
    local requested=("$@") available=() service key
    (( ${#requested[@]} )) || requested=("${_da_services[@]}")
    for service in "${requested[@]}"; do
        if _da_has_secret "$service"; then
            available+=("$service")
        else
            echo "Skipping $service: no key stored (see: secret.sh set $service)" >&2
        fi
    done
    (( ${#available[@]} )) || return 1
    # Read the keys through a pipe, never via a temporary file.
    while IFS=$'\t' read -r service key; do
        _da_fetch_models "$service" "$key"
    done < <(_da_get_secrets "${available[@]}")
    unset key
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
_da_has_secret() {
    "$_da_script_dir/secret.sh" list 2>/dev/null | grep -qx -- "$1"
}

# _da_get_secrets <service>... : prints "<service><TAB><key>" lines. If the
# secrets share a password, it is asked for only once (and gpg-agent, when
# it works, remembers it for a while).
_da_get_secrets() {
    "$_da_script_dir/secret.sh" get-many "$@"
}

# ---------------------------------------------------------------------------
# Reading the chosen models from flags, environment and config files
# ---------------------------------------------------------------------------

# _da_flag_value <flag> <args...>: value of the last --flag X / --flag=X
_da_flag_value() {
    local flag="$1" value="" found=1
    shift
    while (( $# )); do
        case "$1" in
            "$flag") value="${2:-}"; found=0; shift ;;
            "$flag"=*) value="${1#*=}"; found=0 ;;
        esac
        shift
    done
    (( found == 0 )) && echo "$value"
    return $found
}

# Config files in the order aider gives them priority.
_da_config_files() {
    local conf git_root
    conf=$(_da_flag_value --config "$@" || _da_flag_value -c "$@") && { echo "$conf"; return; }
    echo "./.aider.conf.yml"
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) && echo "$git_root/.aider.conf.yml"
    echo "$HOME/.aider.conf.yml"
}

# _da_conf_value <key> <args...>: top-level scalar from the first config
# file that sets it.
_da_conf_value() {
    local key="$1" file line
    shift
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        line=$(grep -E "^${key}:[[:space:]]*[^[:space:]#]" "$file" | tail -n1)
        if [[ -n "$line" ]]; then
            line="${line#*:}"
            line="${line%%#*}"
            line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//")"
            echo "$line"
            return 0
        fi
    done < <(_da_config_files "$@")
    return 1
}

# _da_chosen_model <flag> <env var> <conf key> <args...>
# Same precedence as aider: command line, then AIDER_* variable, then config.
_da_chosen_model() {
    local flag="$1" env_var="$2" key="$3"
    shift 3
    _da_flag_value "$flag" "$@" && return 0
    [[ -n "${!env_var:-}" ]] && { echo "${!env_var}"; return 0; }
    _da_conf_value "$key" "$@"
}

# ---------------------------------------------------------------------------
# The wrapper
# ---------------------------------------------------------------------------

# Used when no flag, AIDER_* variable or config file sets a main model.
_da_default_model="openai/reasoning"
_da_default_editor="openai/coding"
_da_default_weak="openai/desy-assistant"

# The whole function runs in a subshell, so the keys it unlocks never end up
# in your interactive shell.
aider() (
    # Things that don't talk to a model go straight through.
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help|--version|--shell-completions|--shell-completions=*|--list-models|--list-models=*|--models|--models=*)
                exec aider "$@" ;;
        esac
    done

    # Which models will aider use? Same precedence as aider: command line,
    # then AIDER_* variable, then config file.
    # If no main model is set anywhere, use the DESY defaults for all three.
    # If only the main model is set, aider picks editor and weak models to
    # match it, as usual.
    local -a pre=()
    local model editor weak no_model=0
    if ! model=$(_da_chosen_model --model AIDER_MODEL model "$@"); then
        no_model=1
        model="$_da_default_model"
        pre+=(--model "$model")
    fi
    if ! editor=$(_da_chosen_model --editor-model AIDER_EDITOR_MODEL editor-model "$@"); then
        if (( no_model )); then
            editor="$_da_default_editor"
            pre+=(--editor-model "$editor")
        else
            editor="$model"
        fi
    fi
    if ! weak=$(_da_chosen_model --weak-model AIDER_WEAK_MODEL weak-model "$@"); then
        if (( no_model )); then
            weak="$_da_default_weak"
            pre+=(--weak-model "$weak")
        else
            weak="$model"
        fi
    fi

    # Services those models belong to.
    local table main_service="" service m
    local -a needed=()
    table=$(_da_all_models)
    main_service=$(_da_service_of "$model" "$table")
    local seen=" "
    for m in "$model" "$editor" "$weak"; do
        [[ "$seen" == *" $m "* ]] && continue
        seen+="$m "
        if ! service=$(_da_service_of "$m" "$table"); then
            echo "Warning: don't know which service '$m' belongs to, so no key was unlocked for it (see: list_models)." >&2
            continue
        fi
        [[ " ${needed[*]} " == *" $service "* ]] || needed+=("$service")
    done
    for service in "${needed[@]}"; do
        if ! _da_has_secret "$service"; then
            echo "Error: no API key stored for $service. Store one with: $_da_script_dir/secret.sh set $service" >&2
            exit 1
        fi
    done

    # Unlock only those keys (one password prompt if they share a password),
    # and hand them to aider as environment variables (readable only by your
    # own processes), never as flags (readable by every user on the machine
    # via `ps`). Each service also gets its own endpoint.
    local key var base_var
    local -a unlocked=()
    if (( ${#needed[@]} )); then
        echo "Unlocking API keys for: ${needed[*]}"
        while IFS=$'\t' read -r service key; do
            [[ -n "$key" ]] || continue
            var=$(_da_key_var "$service") || continue
            export "$var=$key"
            unlocked+=("$service")
            if base_var=$(_da_base_var "$service"); then
                export "$base_var=$(_da_url "$service")"
            fi
            if _da_is_stale "$service"; then
                _da_fetch_models "$service" "$key"
            fi
        done < <(_da_get_secrets "${needed[@]}")
        unset key
        if (( ${#unlocked[@]} != ${#needed[@]} )); then
            echo "Error: could not unlock all API keys (got: ${unlocked[*]:-none})." >&2
            exit 1
        fi
    fi

    # Aliases for every known model, so short names work on the command line
    # and with /model inside the session.
    local short full
    while read -r service short full; do
        [[ -n "$short" ]] && pre+=(--alias "${short}:${full}")
    done < <(_da_all_models)

    # Repo map and chat history sized for the main model's service. These come
    # before your own arguments, and aider uses the last value it is given, so
    # e.g. `aider --map-tokens 8192` still wins.
    local scale
    scale=$(_da_scale "$main_service")
    pre+=(--map-tokens $(( scale * 1024 ))
          --map-multiplier-no-files $(( 1 + (scale - 1) * 3 / 9 ))
          --max-chat-history-tokens $(( scale * 4000 )))

    if [[ -n "${AIDER_DEV_REPO:-}" && -d "$AIDER_DEV_REPO/aider" ]]; then
        # Run the source checkout with the installed aider's interpreter,
        # which has all of aider's dependencies.
        local python
        python=$(head -n1 "$(type -P aider)" 2>/dev/null | sed -n 's/^#!//p')
        export PYTHONPATH="$AIDER_DEV_REPO${PYTHONPATH:+:$PYTHONPATH}"
        exec "${python:-python3}" -m aider "${pre[@]}" "$@"
    fi
    exec aider "${pre[@]}" "$@"
)

# ---------------------------------------------------------------------------
# Tab completion: model names after the model flags, aider's own completion
# (generated once from `aider --shell-completions bash`) for everything else.
# ---------------------------------------------------------------------------
_da_load_aider_completion() {
    declare -F _shtab_aider >/dev/null && return 0
    local file="$_da_cache_dir/aider-completion.bash" bin
    bin=$(type -P aider) || return 1
    if [[ ! -s "$file" || "$bin" -nt "$file" ]]; then
        mkdir -p "$_da_cache_dir" && command aider --shell-completions bash > "$file" 2>/dev/null || return 1
    fi
    # shellcheck source=/dev/null
    source "$file"
    complete -o bashdefault -o default -F _da_complete aider
}

_da_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]:-}"
    # "--model=xx": bash splits on '=', so prev is "=" and the flag is before it
    if [[ "$prev" == "=" && $COMP_CWORD -ge 2 ]]; then
        prev="${COMP_WORDS[COMP_CWORD-2]}"
    fi
    case "$prev" in
        --model|--editor-model|--weak-model)
            [[ "$cur" == "=" ]] && cur=""
            mapfile -t COMPREPLY < <(compgen -W "$(_da_short_names)" -- "$cur")
            return 0 ;;
    esac
    if _da_load_aider_completion; then
        _shtab_aider "$@"
    fi
}

complete -o bashdefault -o default -F _da_complete aider
