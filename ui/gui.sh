#!/usr/bin/env bash
# Zenity GUI front-end for Boom configuration. Writes to provided config file path.
set -euo pipefail
CFG_PATH="${1:-}"
if [[ -z "$CFG_PATH" ]]; then
  echo "Usage: $0 /path/to/meeting.conf"
  exit 2
fi
if ! command -v zenity >/dev/null 2>&1; then
  echo "zenity not found"
  exit 1
fi

# Prompt meeting id & psk; exit immediately if user closes/cancels any dialog.
MEETING_ID=$(zenity --entry --title="Boom — Meeting ID" --text="Enter Meeting ID:" --entry-text "" )
status=$?
if (( status != 0 )); then exit 1; fi
if [[ -z "$MEETING_ID" ]]; then
  zenity --error --title="Boom" --text="Meeting ID required"
  exit 1
fi

PSK=$(zenity --password --title="Boom — Passcode" --text="Enter Passcode (PSK):")
status=$?
if (( status != 0 )); then exit 1; fi
# allow empty PSK but user can cancel to abort

DAYS=$(zenity --entry --title="Boom — Days" --text="Days (comma-separated or 'every', e.g. mon,wed):" --entry-text "every")
status=$?
if (( status != 0 )); then exit 1; fi
if [[ -z "$DAYS" ]]; then DAYS="every"; fi

# Convert to list
parse_days() {
  local raw="${1,,}"
  if [[ "$raw" == "every" ]]; then
    echo "Mon Tue Wed Thu Fri Sat Sun"
    return
  fi
  IFS=',' read -r -a parts <<< "$raw"
  for p in "${parts[@]}"; do
    p="${p// /}"
    case "$p" in
      mon*|m) echo -n "Mon " ;;
      tue*|tu) echo -n "Tue " ;;
      wed*|w) echo -n "Wed " ;;
      thu*|th) echo -n "Thu " ;;
      fri*|f) echo -n "Fri " ;;
      sat*|s) echo -n "Sat " ;;
      sun*|su) echo -n "Sun " ;;
    esac
  done
}

SCHEDULE_MAP=""
for d in $(parse_days "$DAYS"); do
  while true; do
    t=$(zenity --entry --title="Time for $d" --text="Enter time for $d (HH:MM 24h):" --entry-text "09:00")
    status=$?
    if (( status != 0 )); then
      exit 1
    fi
    if [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      SCHEDULE_MAP+="${SCHEDULE_MAP:+,}${d}=${t}"
      break
    else
      zenity --error --title="Boom" --text="Invalid time format for $d. Use HH:MM (24-hour)."
      # if user clicks OK we re-prompt for this day; closing the error dialog continues loop and re-prompts
    fi
  done
done

# Write config
mkdir -p "$(dirname "$CFG_PATH")"
umask 177
cat > "$CFG_PATH" <<EOF
MEETING_ID=${MEETING_ID}
PSK=${PSK}
SCHEDULE_DAYS=${DAYS}
SCHEDULE_MAP=${SCHEDULE_MAP}
EOF
chmod 600 "$CFG_PATH"

zenity --info --title="Boom" --text="Saved to $CFG_PATH"
exit 0