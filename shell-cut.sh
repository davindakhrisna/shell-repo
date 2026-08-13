#!/usr/bin/env bash

# Change the directory of .env as you see fit
DIR="$(dirname "$(realpath "$0")")"
ENV_FILE="$DIR/.env" 
[ -f "$ENV_FILE" ] || ENV_FILE="$HOME/nixos-config/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

KEYS=("$GOOGLE_API_KEY" "$GOOGLE_API_KEY_BACKUP" "$GOOGLE_API_KEY_TERTIARY")

simplify_error() {
    local err_str=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    if [[ "$err_str" == *"429"* || "$err_str" == *"quota"* || "$err_str" == *"exhausted"* ]]; then
        echo "Error: API Quota Exceeded"
    elif [[ "$err_str" == *"timeout"* || "$err_str" == *"504"* || "$err_str" == *"deadline"* ]]; then
        echo "Error: Timeout Exceeded"
    elif [[ "$err_str" == *"400"* || "$err_str" == *"bad request"* ]]; then
        echo "Error: Bad Request"
    elif [[ "$err_str" == *"grim"* ]]; then
        echo "Error: Screen Capture Failed"
    else
        echo "Error: ${err_str:0:40}..."
    fi
}

notify() {
    local text="$1"
    if [ -n "$2" ]; then
        text="$2"
    fi
    
    # Escape HTML entities
    local safe_message=$(echo "$text" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    local stealth_message="<span size='x-small'>${safe_message}</span>"
    
    notify-send -a "pyCheat" -u low -t 60000 "" "$stealth_message"
}

notify_error() {
    local err_msg="$(simplify_error "$1")"
    notify "$err_msg"
}

clear_notifications() {
    echo "Clearing all desktop notifications..."
    if command -v dunstctl &> /dev/null; then
        dunstctl close-all
        echo "Done! Notifications cleared."
    else
        echo "Error: dunstctl CLI not found."
        exit 1
    fi
}

simulate_notifications() {
    echo "Simulating pyCheat Notifications..."

    echo "1. Triggering Success Notification with Unicode Math..."
    notify "∫ x² dx = x³/3 + C"
    sleep 2

    echo "1b. Triggering Success Notification with raw characters..."
    notify "0 < x < 5"
    sleep 2

    local mock_errors=(
        "429 Quota exhausted for project"
        "504 Gateway Timeout deadline exceeded"
        "400 Bad Request: Invalid payload"
        "grim failed to capture output"
        "Some completely unknown random exception that broke everything"
    )

    local i=2
    for err_msg in "${mock_errors[@]}"; do
        echo "$i. Triggering Error Notification for: $err_msg"
        notify_error "$err_msg"
        sleep 2
        ((i++))
    done

    echo "Done! Check your desktop notifications."
}

run_solver() {
    TMP_IMG=$(mktemp /tmp/shellcut-img-XXXXXX.jpg)
    TMP_JSON=$(mktemp /tmp/shellcut-json-XXXXXX.json)
    trap 'rm -f "$TMP_IMG" "$TMP_JSON"' EXIT

    # Capture screen to JPEG
    grim -t jpeg "$TMP_IMG" 2>/dev/null
    if [ ! -s "$TMP_IMG" ]; then
        notify_error "grim failed"
        rm -f "$TMP_IMG" "$TMP_JSON"
        exit 1
    fi

    PROMPT="Analyze the problem shown in the image and give me ONLY the answer(s).
CRITICAL: You MUST NOT output any steps, headings, reasoning, formulas, or conversational text.
Output EXACTLY the final answer(s) string and nothing else.

Rules:
- Do not use MARKDOWN notation, only raw texts.
- For multiple-choice questions WITH letters (A, B, C, D), output ONLY the correct letter(s) (e.g., 'A & C').
- For multiple-choice questions WITHOUT letters, output ONLY 'Option 1', 'Option 2', etc., corresponding to the correct answer's position from top to bottom.
- For mathematical formulas, DO NOT output LaTeX syntax. You MUST use standard Unicode math symbols (e.g., use ∫ x² dx).
- Just skip any step-by-step and go straight to the answer."

    # Construct JSON Payload using stdin to avoid command line argument length limits
    base64 -w 0 "$TMP_IMG" | jq -Rs --arg prompt "$PROMPT" '{
      "contents": [
        {
          "parts": [
            {
              "inlineData": {
                "mimeType": "image/jpeg",
                "data": (gsub("\n|\r"; ""))
              }
            },
            {
              "text": $prompt
            }
          ]
        }
      ]
    }' > "$TMP_JSON"

    MODEL="gemini-3.5-flash"
    SUCCESS=0
    ERROR_MSG="No valid API keys found"

    for KEY in "${KEYS[@]}"; do
        if [ -z "$KEY" ]; then
            continue
        fi

        # Make the HTTP POST Request using -d @file to avoid argument size limits
        RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${KEY}" \
            -H "Content-Type: application/json" \
            -d @"$TMP_JSON")
        
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')

        if [ "$HTTP_CODE" -eq 200 ]; then
            # Parse output safely with jq
            ANSWER=$(echo "$BODY" | jq -r '.candidates[0].content.parts[0].text // empty')
            
            if [ -n "$ANSWER" ]; then
                # Strip whitespace
                ANSWER=$(echo "$ANSWER" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                notify "$ANSWER"
                SUCCESS=1
                break
            else
                ERROR_MSG="No answer received"
            fi
        else
            # Extract error message for fallback check
            API_ERR=$(echo "$BODY" | jq -r '.error.message // empty' 2>/dev/null)
            if [ -n "$API_ERR" ]; then
                ERROR_MSG="${HTTP_CODE} ${API_ERR}"
            else
                ERROR_MSG="${HTTP_CODE} API Error"
            fi
        fi
    done

    if [ $SUCCESS -eq 0 ]; then
        notify_error "$ERROR_MSG"
    fi
}

case "$1" in
    --clear|-c)
        clear_notifications
        ;;
    --simulate|-s)
        simulate_notifications
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --clear, -c      Clear all active desktop notifications"
        echo "  --simulate, -s   Run notification styling simulation"
        echo "  --help, -h       Show this help message"
        echo "  (no arguments)   Capture screen and solve with Gemini AI"
        ;;
    "")
        run_solver
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use '$0 --help' for usage options."
        exit 1
        ;;
esac
