#!/bin/sh
# A stand-in for the `claude` CLI, for tests. POSIX sh + awk only, so it runs on Linux CI and macOS.
#
# `--version` / `-v` prints "$FAKE_CLAUDE_VERSION (Claude Code)" (default 2.1.300).
# Otherwise it reads the transcript on stdin and behaves according to FAKE_CLAUDE_MODE:
#   ok-echo    (default) echo the transcript back, without its <transcript> tags, as a successful JSON result
#   fenced     the same, wrapped in a ``` code fence
#   slow       sleep FAKE_CLAUDE_DELAY seconds (default 3), then ok-echo
#   fail       print an error on stderr and exit 1
#   auth-fail  print an is_error JSON result about authentication on stdout and exit 1 (what claude -p does)
#   rate-limit print an is_error JSON result about a usage limit and exit 1
#   hang       never answer (until killed)
#   linger     ok-echo, then stay running (until killed): a claude that answered but is slow to exit
#   essay      answer with a long essay (fails Tidy's length check)
#   empty      a successful JSON result with an empty result
#   garbage    print something that isn't JSON and exit 0
#
# FAKE_CLAUDE_RECORD=<file>: also write the arguments (one per line), a "--- env" line and the environment there.
#
# devshout gives claude a clean environment, so these settings can also come from a `fake-claude.env` file (sh
# assignments) in $CLAUDE_CONFIG_DIR, or failing that in $HOME/.claude. Tests symlink a `claude` to this script.

set -u

for settings in "${CLAUDE_CONFIG_DIR:-/nonexistent}/fake-claude.env" "${HOME:-/nonexistent}/.claude/fake-claude.env"; do
    if [ -f "$settings" ]; then
        . "$settings"
        break
    fi
done

json_escape() {
    # stdin → one JSON string body (no quotes): escapes \ " tab and CR, and joins lines with \n.
    # sed does the escaping (awk's gsub treats backslashes differently from one awk to the next).
    tab=$(printf '\t')
    cr=$(printf '\r')
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$tab/\\\\t/g" -e "s/$cr/\\\\r/g" |
        awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

result_json() {
    # $1 = is_error (true/false), $2 = subtype, $3 = escaped result text
    printf '{"type":"result","subtype":"%s","is_error":%s,"duration_ms":1234,"duration_api_ms":1100,"num_turns":1,"result":"%s","stop_reason":"end_turn","session_id":"00000000-0000-4000-8000-000000000000","total_cost_usd":0.00042,"usage":{"input_tokens":120,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":80,"service_tier":"standard"},"modelUsage":{"claude-haiku-fake":{"inputTokens":120,"outputTokens":80,"costUSD":0.00042}},"permission_denials":[],"uuid":"11111111-1111-4111-8111-111111111111","future_field":{"nested":[1,2,3]}}\n' "$2" "$1" "$3"
}

for arg in "$@"; do
    case "$arg" in
        --version|-v)
            printf '%s (Claude Code)\n' "${FAKE_CLAUDE_VERSION:-2.1.300}"
            exit 0
            ;;
    esac
done

if [ -n "${FAKE_CLAUDE_RECORD:-}" ]; then
    {
        for arg in "$@"; do printf '%s\n' "$arg"; done
        printf -- '--- env\n'
        env
    } > "$FAKE_CLAUDE_RECORD"
fi

input=$(cat)
transcript=$(printf '%s\n' "$input" | sed -e '/^<transcript>$/d' -e '/^<\/transcript>$/d')

mode=${FAKE_CLAUDE_MODE:-ok-echo}
case "$mode" in
    ok-echo)
        result_json false success "$(printf '%s' "$transcript" | json_escape)"
        ;;
    fenced)
        result_json false success "$(printf '```markdown\n%s\n```' "$transcript" | json_escape)"
        ;;
    slow)
        # Stop the sleep too when we're told to stop, so no orphan outlives the test.
        sleep "${FAKE_CLAUDE_DELAY:-3}" &
        sleeper=$!
        trap 'kill "$sleeper" 2>/dev/null; exit 143' TERM INT
        wait "$sleeper"
        trap - TERM INT
        result_json false success "$(printf '%s' "$transcript" | json_escape)"
        ;;
    fail)
        echo "Error: something went wrong in the fake claude" >&2
        exit 1
        ;;
    auth-fail)
        result_json true success "Failed to authenticate. API Error: 401 {\\\"type\\\":\\\"error\\\",\\\"error\\\":{\\\"type\\\":\\\"authentication_error\\\",\\\"message\\\":\\\"OAuth token has expired.\\\"}}"
        exit 1
        ;;
    rate-limit)
        result_json true success "Claude AI usage limit reached. Your limit will reset at 3pm (Europe/London)."
        exit 1
        ;;
    hang)
        exec sleep 600
        ;;
    linger)
        result_json false success "$(printf '%s' "$transcript" | json_escape)"
        exec sleep 600
        ;;
    essay)
        essay="Great question! Here is a detailed answer to what you asked."
        i=0
        while [ $i -lt 40 ]; do
            essay="$essay This paragraph explores the topic in more depth, adding context, caveats and examples."
            i=$((i + 1))
        done
        result_json false success "$essay"
        ;;
    empty)
        result_json false success ""
        ;;
    garbage)
        echo "Lorem ipsum ~~~ this is not JSON at all {"
        ;;
    *)
        echo "fake-claude: unknown FAKE_CLAUDE_MODE '$mode'" >&2
        exit 2
        ;;
esac
