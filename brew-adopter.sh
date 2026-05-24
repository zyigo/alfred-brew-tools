#!/usr/bin/env bash

# Brew Adopter — Alfred Run Script wrapper
#
# Paste this whole file into Alfred's "Run Script" action.
#
# Alfred setup:
#   Keyword → Run Script
#   Language: /bin/bash
#
# Requires:
#   brew install tmux gum jq
#
# Optional fallback:
#   brew install fzf

TMP_ID="$$-$(date +%s)"
SESSION_NAME="brew-adopter-${TMP_ID}"
TMP_SCRIPT="/tmp/alfred-brew-adopter-${TMP_ID}.sh"
TMP_HEADER="/tmp/alfred-brew-adopter-header-${TMP_ID}.sh"
TMP_DONE="/tmp/alfred-brew-adopter-done-${TMP_ID}.marker"
TMP_COMMAND="/tmp/alfred-brew-adopter-${TMP_ID}.command"

cat > "$TMP_HEADER" <<'HEADER_EOF'
#!/usr/bin/env bash

while true; do
    clear
    printf '╭─ 🍺 Brew Adopter ─────────────────────────────────────────────────────────╮\n'
    printf '│ Adopt installed macOS apps into Homebrew Cask · Ignore unwanted matches   │\n'
    printf '│ Space: select · Enter: confirm · Esc/Ctrl-C: exit                         │\n'
    printf '╰───────────────────────────────────────────────────────────────────────────╯\n'
    sleep 3600
done
HEADER_EOF

cat > "$TMP_SCRIPT" <<'SCRIPT_EOF'
#!/usr/bin/env bash

SESSION_NAME="${1:-}"

has() {
    command -v "$1" >/dev/null 2>&1
}

section() {
    if has gum; then
        gum style --foreground 99 --bold --margin "1 0 0 0" "$1"
    else
        printf '\n────────────────────────────────────────────────────────────\n%s\n────────────────────────────────────────────────────────────\n' "$1"
    fi
}

note() {
    if has gum; then
        gum style --foreground 245 "  $1"
    else
        printf '  %s\n' "$1"
    fi
}

ok() {
    if has gum; then
        gum style --foreground 42 "  ✅ $1"
    else
        printf '  ✅ %s\n' "$1"
    fi
}

warn() {
    if has gum; then
        gum style --foreground 214 "  ⚠️  $1"
    else
        printf '  ⚠️  %s\n' "$1"
    fi
}

fail() {
    if has gum; then
        gum style --foreground 196 "  ❌ $1"
    else
        printf '  ❌ %s\n' "$1"
    fi
}

spin_or_run() {
    local title="$1"
    shift

    if has gum; then
        gum spin --spinner dot --title "$title" -- "$@"
    else
        note "$title"
        "$@"
    fi
}

close_app() {
    if [ -n "${SESSION_NAME:-}" ] && has tmux; then
        tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
    fi
    exit 0
}

confirm() {
    local prompt="$1"

    if has gum; then
        gum confirm --default=true "$prompt"
        return $?
    fi

    local response
    read -r -p "$prompt [Y/n] " response
    case "$response" in
        n|N|no|NO) return 1 ;;
        *) return 0 ;;
    esac
}

pause_after_operation() {
    # Keep this intentionally tiny so the TUI feels responsive after adopt/ignore.
    sleep 0.15
}

numbered_candidate_list() {
    local i=1
    local token
    local app_paths

    while IFS= read -r token; do
        app_paths="$(awk -F $'\t' -v token="$token" '$1 == token {print $3}' "$MATCHES" | sort -u | paste -sd ', ' -)"
        printf '%2d) %s\n    %s\n\n' "$i" "$token" "$app_paths"
        i=$((i + 1))
    done < "$CANDIDATES"
}

parse_selection() {
    local input="$1"
    local max="$2"
    local part
    local start
    local end
    local n

    : > "$SELECTED_CANDIDATES"

    input="$(printf '%s' "$input" | tr ',' ' ' | xargs 2>/dev/null || true)"

    if [ -z "$input" ]; then
        return 1
    fi

    if [ "$input" = "a" ] || [ "$input" = "A" ] || [ "$input" = "all" ] || [ "$input" = "ALL" ]; then
        cp "$CANDIDATES" "$SELECTED_CANDIDATES"
        return 0
    fi

    for part in $input; do
        case "$part" in
            *-*)
                start="${part%-*}"
                end="${part#*-}"

                if ! [[ "$start" =~ ^[0-9]+$ ]] || ! [[ "$end" =~ ^[0-9]+$ ]]; then
                    warn "Ignoring invalid range: $part"
                    continue
                fi

                if [ "$start" -gt "$end" ]; then
                    warn "Ignoring backwards range: $part"
                    continue
                fi

                n="$start"
                while [ "$n" -le "$end" ]; do
                    if [ "$n" -ge 1 ] && [ "$n" -le "$max" ]; then
                        sed -n "${n}p" "$CANDIDATES" >> "$SELECTED_CANDIDATES"
                    else
                        warn "Ignoring out-of-range number: $n"
                    fi
                    n=$((n + 1))
                done
                ;;
            *)
                if ! [[ "$part" =~ ^[0-9]+$ ]]; then
                    warn "Ignoring invalid selection: $part"
                    continue
                fi

                if [ "$part" -ge 1 ] && [ "$part" -le "$max" ]; then
                    sed -n "${part}p" "$CANDIDATES" >> "$SELECTED_CANDIDATES"
                else
                    warn "Ignoring out-of-range number: $part"
                fi
                ;;
        esac
    done

    sort -u "$SELECTED_CANDIDATES" -o "$SELECTED_CANDIDATES"
    [ -s "$SELECTED_CANDIDATES" ]
}

adopt_from_file() {
    local file="$1"
    local token
    local adopted=0
    local failed=0

    while IFS= read -r token; do
        [ -z "$token" ] && continue

        section "Adopting $token"

        if "$BREW" install --cask --adopt "$token"; then
            adopted=$((adopted + 1))
            ok "Adopted $token"
        else
            failed=$((failed + 1))
            fail "Failed $token"
        fi
    done < "$file"

    section "Result"
    ok "Adopted $adopted cask(s)"
    if [ "$failed" != "0" ]; then
        warn "Failed $failed cask(s)"
    fi
}

ignore_from_file() {
    local file="$1"
    local token
    local ignored_count

    touch "$IGNORE_FILE"

    while IFS= read -r token; do
        [ -z "$token" ] && continue
        printf '%s\n' "$token" >> "$IGNORE_FILE"
    done < "$file"

    # Remove duplicates and blank lines.
    grep -v '^[[:space:]]*$' "$IGNORE_FILE" 2>/dev/null | sort -u > "$TMP_DIR/ignored-clean.txt" || true
    mv "$TMP_DIR/ignored-clean.txt" "$IGNORE_FILE"

    ignored_count="$(grep -c '[^[:space:]]' "$file" 2>/dev/null || echo 0)"
    ok "Ignored $ignored_count item(s)"
    note "Ignore list: $IGNORE_FILE"
}

choose_candidates_with_gum() {
    local display_file="$TMP_DIR/gum-display.tsv"
    local selected_lines
    local token
    local app_paths

    : > "$SELECTED_CANDIDATES"
    : > "$display_file"

    while IFS= read -r token; do
        app_paths="$(awk -F $'\t' -v token="$token" '$1 == token {print $3}' "$MATCHES" | sort -u | paste -sd ', ' -)"
        printf '%s\t%s\n' "$token" "$app_paths" >> "$display_file"
    done < "$CANDIDATES"

    section "Select casks"
    note "Use ↑/↓ to move, / to filter, Space to select, Enter to confirm."
    echo

    selected_lines="$(
        gum choose \
            --no-limit \
            --height 18 \
            --cursor.foreground 212 \
            --selected.foreground 42 \
            --header "Select casks to manage" \
            < "$display_file"
    )"

    if [ -z "$selected_lines" ]; then
        return 1
    fi

    printf '%s\n' "$selected_lines" | awk -F $'\t' '{print $1}' | sort -u > "$SELECTED_CANDIDATES"
    [ -s "$SELECTED_CANDIDATES" ]
}

choose_action_with_gum() {
    # This function is called via ACTION="$(choose_action_with_gum)".
    # Keep stdout machine-readable only: adopt, ignore, or cancel.
    local action_choices="$TMP_DIR/action-choices.txt"
    local action_line
    local action_normalised

    section "Action" > /dev/tty
    note "Choose what to do with the selected cask(s)." > /dev/tty

    printf '%s\n' \
        "adopt selected cask(s)" \
        "ignore selected cask(s)" \
        "cancel" > "$action_choices"

    action_line="$(
        gum choose \
            --cursor.foreground 212 \
            --selected.foreground 42 \
            --header "Choose an action" \
            < "$action_choices"
    )"

    action_normalised="$(
        printf '%s' "$action_line" |
        tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z]/ /g' |
        xargs 2>/dev/null || true
    )"

    case "$action_normalised" in
        *adopt*) printf '%s\n' "adopt" ;;
        *ignore*) printf '%s\n' "ignore" ;;
        *) printf '%s\n' "cancel" ;;
    esac
}

choose_with_fzf() {
    local display_file="$TMP_DIR/fzf-display.tsv"
    local selected_lines
    local fzf_exit
    local token
    local app_paths

    : > "$SELECTED_CANDIDATES"
    : > "$display_file"

    while IFS= read -r token; do
        app_paths="$(awk -F $'\t' -v token="$token" '$1 == token {print $3}' "$MATCHES" | sort -u | paste -sd ', ' -)"
        printf '%s\t%s\n' "$token" "$app_paths" >> "$display_file"
    done < "$CANDIDATES"

    section "Choose casks"
    note "↑/↓ move · type to search · Tab select · Enter confirm · Esc cancel"
    echo

    selected_lines="$(
        cat "$display_file" |
        fzf \
            --multi \
            --height=85% \
            --layout=reverse \
            --border=rounded \
            --prompt='Casks > ' \
            --pointer='▶' \
            --marker='✓' \
            --header='Tab = select multiple · Enter = confirm · Esc = cancel' \
            --with-nth=1,2 \
            --preview='printf "Cask: %s\nApp:  %s\n" {1} {2}' \
            --preview-window=down:4:wrap
    )"

    fzf_exit=$?
    if [ "$fzf_exit" != "0" ] || [ -z "$selected_lines" ]; then
        return 1
    fi

    printf '%s\n' "$selected_lines" | awk -F $'\t' '{print $1}' | sort -u > "$SELECTED_CANDIDATES"
    [ -s "$SELECTED_CANDIDATES" ]
}

choose_action_with_fzf() {
    local action
    local action_normalised

    action="$(
        printf '%s\n' \
            "adopt	Adopt selected cask(s) with Homebrew" \
            "ignore	Hide selected cask(s) from future runs" \
            "cancel	Do nothing" |
        fzf \
            --height=40% \
            --layout=reverse \
            --border=rounded \
            --prompt='Action > ' \
            --header='Choose what to do with the selected items' \
            --with-nth=1,2
    )"

    action_normalised="$(
        printf '%s' "$action" |
        tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z]/ /g' |
        xargs 2>/dev/null || true
    )"

    case "$action_normalised" in
        *adopt*) printf '%s\n' "adopt" ;;
        *ignore*) printf '%s\n' "ignore" ;;
        *) printf '%s\n' "cancel" ;;
    esac
}

choose_with_numbered_fallback() {
    local selection

    section "Choose casks"
    warn "Neither gum nor fzf is installed, so using numbered fallback."
    note "Install gum for the TUI: brew install gum"
    echo

    numbered_candidate_list

    echo "Choose casks."
    echo "Examples:"
    echo "  1 3 7"
    echo "  2-5"
    echo "  1,4,6"
    echo "  a     select all"
    echo
    read -r -p "Selection, or Enter to cancel: " selection

    parse_selection "$selection" "$COUNT"
}

choose_action_fallback() {
    local action_choice

    {
        echo
        echo "What do you want to do?"
        echo "  1) Adopt selected items"
        echo "  2) Ignore selected items"
        echo "  3) Cancel"
        echo
    } > /dev/tty

    read -r -p "Choice [1-3]: " action_choice < /dev/tty

    case "$action_choice" in
        1) echo "adopt" ;;
        2) echo "ignore" ;;
        *) echo "cancel" ;;
    esac
}

show_stats_panel() {
    if has gum; then
        gum style \
            --border rounded \
            --padding "1 2" \
            --margin "1 0" \
            --width 78 \
            "Visible candidates: $COUNT" \
            "Ignored list:       $IGNORE_FILE" \
            "Metadata cache:     $CASKS_JSON"
    else
        note "Visible candidates: $COUNT"
        note "Ignored list: $IGNORE_FILE"
        note "Metadata cache: $CASKS_JSON"
    fi
}

initialise() {
    CONFIG_DIR="$HOME/.config/alfred-brew-adopt"
    CACHE_DIR="$HOME/Library/Caches/alfred-adoptable-casks"
    IGNORE_FILE="$CONFIG_DIR/ignored-casks.txt"

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CACHE_DIR"
    touch "$IGNORE_FILE"

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    INSTALLED_CASKS="$TMP_DIR/installed-casks.txt"
    INSTALLED_APPS="$TMP_DIR/installed-apps.tsv"
    MATCHES="$TMP_DIR/matches.tsv"
    CANDIDATES="$TMP_DIR/candidates.txt"
    SELECTED_CANDIDATES="$TMP_DIR/selected-candidates.txt"
    CASKS_JSON="$CACHE_DIR/brew-casks.json"

    PRERELEASE_REGEX='(^|[@-])(alpha|beta|prerelease|pre-release|nightly|insiders|tip|canary|dev|developer|developer-preview|preview|rc|snapshot|edge|eap|early-access)($|[@-])'
}

check_tools() {
    clear
    section "Checking tools"

    if [ -x /opt/homebrew/bin/brew ]; then
        BREW=/opt/homebrew/bin/brew
    elif [ -x /usr/local/bin/brew ]; then
        BREW=/usr/local/bin/brew
    else
        fail "Homebrew not found"
        close_app
    fi

    eval "$("$BREW" shellenv)"

    if ! has jq; then
        fail "jq not found"
        note "Install it with: brew install jq"
        close_app
    fi

    ok "Homebrew found: $BREW"
    ok "jq found"

    if has gum; then
        ok "gum found"
    elif has fzf; then
        warn "gum not found; fzf fallback will be used"
        note "Install gum for the nicer TUI: brew install gum"
    else
        warn "gum/fzf not found; numbered fallback will be used"
        note "Install gum for the nicer TUI: brew install gum"
    fi
}

load_metadata() {
    section "Loading Homebrew Cask metadata"

    local refresh=false
    if [ ! -s "$CASKS_JSON" ]; then
        refresh=true
        note "No cache found"
    else
        local now
        local modified
        local age

        now="$(date +%s)"
        modified="$(stat -f %m "$CASKS_JSON" 2>/dev/null || echo 0)"
        age=$((now - modified))

        if [ "$age" -gt 86400 ]; then
            refresh=true
            note "Cache older than 24 hours"
        else
            ok "Using cached metadata"
        fi
    fi

    if [ "$refresh" = true ]; then
        if spin_or_run "Fetching metadata. First run can take a few minutes..." "$BREW" info --json=v2 --cask --eval-all > "$CASKS_JSON"; then
            ok "Metadata updated"
        else
            fail "Could not fetch cask metadata"
            close_app
        fi
    fi
}

build_candidates() {
    "$BREW" list --cask 2>/dev/null | sort -u > "$INSTALLED_CASKS" || true

    : > "$INSTALLED_APPS"
    : > "$MATCHES"
    : > "$CANDIDATES"
    : > "$SELECTED_CANDIDATES"

    local app_dir
    local app_path
    local app_name

    for app_dir in "/Applications" "$HOME/Applications"; do
        if [ -d "$app_dir" ]; then
            find "$app_dir" -maxdepth 1 -name "*.app" -type d -print 2>/dev/null |
            while IFS= read -r app_path; do
                app_name="$(basename "$app_path")"
                printf '%s\t%s\n' "$app_name" "$app_path" >> "$INSTALLED_APPS"
            done
        fi
    done

    APP_COUNT="$(grep -c '[^[:space:]]' "$INSTALLED_APPS" 2>/dev/null || echo 0)"

    while IFS=$'\t' read -r app_name app_path; do
        jq -r --arg app "$app_name" --arg path "$app_path" '
            .casks[]
            | select(
                [
                    .artifacts[]?
                    | objects
                    | .app[]?
                    | if type == "string" then .
                      elif type == "object" and has("target") then .target
                      else empty
                      end
                ]
                | index($app)
            )
            | [.token, $app, $path]
            | @tsv
        ' "$CASKS_JSON" >> "$MATCHES"
    done < "$INSTALLED_APPS"

    if [ ! -s "$MATCHES" ]; then
        return 1
    fi

    awk -F $'\t' '{print $1}' "$MATCHES" | sort -u > "$TMP_DIR/all-candidates.txt"

    if [ -s "$INSTALLED_CASKS" ]; then
        comm -23 "$TMP_DIR/all-candidates.txt" "$INSTALLED_CASKS" > "$CANDIDATES"
    else
        cp "$TMP_DIR/all-candidates.txt" "$CANDIDATES"
    fi

    grep -Eiv "$PRERELEASE_REGEX" "$CANDIDATES" > "$TMP_DIR/stable-candidates.txt" || true
    mv "$TMP_DIR/stable-candidates.txt" "$CANDIDATES"

    # Apply ignore list, ignoring blank lines.
    grep -v '^[[:space:]]*$' "$IGNORE_FILE" 2>/dev/null > "$TMP_DIR/active-ignore.txt" || true
    if [ -s "$TMP_DIR/active-ignore.txt" ]; then
        grep -Fvxf "$TMP_DIR/active-ignore.txt" "$CANDIDATES" > "$TMP_DIR/not-ignored-candidates.txt" || true
        mv "$TMP_DIR/not-ignored-candidates.txt" "$CANDIDATES"
    fi

    [ -s "$CANDIDATES" ]
}

render_current_state() {
    clear
    section "Scanning apps"

    ok "Found $APP_COUNT app bundle(s)"

    if [ ! -s "$MATCHES" ]; then
        ok "No matching Homebrew Cask candidates found"
        return
    fi

    COUNT="$(grep -c '[^[:space:]]' "$CANDIDATES" 2>/dev/null || echo 0)"

    if [ "$COUNT" = "0" ]; then
        ok "No visible stable adoptable casks found"
        note "Ignored items live here: $IGNORE_FILE"
    else
        ok "Found $COUNT visible adoptable cask candidate(s)"
        show_stats_panel
    fi
}

all_done_and_close() {
    clear
    section "All done"
    ok "No visible adoptable casks remaining"
    note "Ignored items live here: $IGNORE_FILE"
    sleep 1.2
    close_app
}

main_loop() {
    local action
    local token

    while true; do
        if ! build_candidates; then
            all_done_and_close
        fi

        render_current_state

        COUNT="$(grep -c '[^[:space:]]' "$CANDIDATES" 2>/dev/null || echo 0)"
        if [ "$COUNT" = "0" ]; then
            all_done_and_close
        fi

        if has gum; then
            if ! choose_candidates_with_gum; then
                close_app
            fi
        elif has fzf; then
            if ! choose_with_fzf; then
                close_app
            fi
        else
            if ! choose_with_numbered_fallback; then
                close_app
            fi
        fi

        section "Selected"
        while IFS= read -r token; do
            printf '  • %s\n' "$token"
        done < "$SELECTED_CANDIDATES"

        if has gum; then
            action="$(choose_action_with_gum || echo cancel)"
        elif has fzf; then
            action="$(choose_action_with_fzf || echo cancel)"
        else
            action="$(choose_action_fallback)"
        fi

        case "$action" in
            adopt)
                if confirm "Attempt adoption for selected casks?"; then
                    section "Adopting selected casks"
                    adopt_from_file "$SELECTED_CANDIDATES"
                    pause_after_operation
                    continue
                else
                    warn "Cancelled. Nothing adopted."
                    sleep 1
                fi
                ;;
            ignore)
                if confirm "Ignore selected casks in future runs?"; then
                    section "Ignoring selected casks"
                    ignore_from_file "$SELECTED_CANDIDATES"
                    pause_after_operation
                    continue
                else
                    warn "Cancelled. Nothing ignored."
                    sleep 1
                fi
                ;;
            cancel)
                close_app
                ;;
            *)
                warn "Unknown action returned by menu: '$action'"
                warn "Returning to the menu."
                sleep 2
                ;;
        esac
    done
}

initialise
check_tools
load_metadata
main_loop
SCRIPT_EOF

chmod +x "$TMP_HEADER"
chmod +x "$TMP_SCRIPT"

cat > "$TMP_COMMAND" <<EOF
#!/usr/bin/env bash

resize_front_terminal_window() {
    osascript <<OSA >/dev/null 2>&1
tell application "Terminal"
    activate
    set bounds of front window to {140, 100, 1080, 720}
    try
        set number of columns of front window to 104
        set number of rows of front window to 30
    end try
end tell
OSA
}

resize_front_terminal_window
sleep 0.25
resize_front_terminal_window

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is required for this version."
    echo "Install it with: brew install tmux"
    sleep 2
    touch "$TMP_DONE"
    rm -f "$TMP_SCRIPT" "$TMP_HEADER" "$TMP_COMMAND"
    exit 0
fi

tmux new-session -d -s "$SESSION_NAME" "$TMP_SCRIPT" "$SESSION_NAME"

tmux set-option -t "$SESSION_NAME" mouse on
tmux set-option -t "$SESSION_NAME" focus-events on
tmux set-option -t "$SESSION_NAME" escape-time 0
tmux set-option -t "$SESSION_NAME" status on

tmux split-window -v -b -l 4 -t "$SESSION_NAME":0.0 "$TMP_HEADER"
tmux select-pane -t "$SESSION_NAME":0.1
tmux attach-session -t "$SESSION_NAME"

touch "$TMP_DONE"
rm -f "$TMP_SCRIPT" "$TMP_HEADER" "$TMP_COMMAND"
exit 0
EOF

chmod +x "$TMP_COMMAND"
xattr -d com.apple.quarantine "$TMP_COMMAND" 2>/dev/null || true

# Open a dedicated Terminal window and remember its window id.
WINDOW_ID="$(
osascript <<OSA
tell application "Terminal"
    activate
    set newTab to do script "\"$TMP_COMMAND\""
    delay 0.2
    set targetWindow to front window
    return id of targetWindow
end tell
OSA
)"

# Alfred-side monitor:
# Wait until the .command script has exited cleanly, then close that exact window.
# Because the shell has already exited, Terminal should not show the
# "terminate running processes" warning.
(
    while [ ! -f "$TMP_DONE" ]; do
        sleep 0.25
    done

    sleep 0.4

    osascript <<OSA >/dev/null 2>&1
tell application "Terminal"
    try
        close (first window whose id is $WINDOW_ID)
    end try
end tell
OSA

    rm -f "$TMP_DONE"
) >/dev/null 2>&1 &
