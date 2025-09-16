#!/usr/bin/env bash
# Zenity helpers for Boom GUI. Define run_zenity_ui <config_path>.
# This file is safe to source: it does not call exit, only returns status codes.

# Check zenity availability
zenity_check() {
  if ! command -v zenity >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Normalize days input into Titlecase 3-letter tokens
zenity_parse_days() {
  local raw="${1,,}"
  if [[ "$raw" == "every" || -z "$raw" ]]; then
    echo "Mon Tue Wed Thu Fri Sat Sun"
    return 0
  fi
  IFS=',' read -r -a parts <<< "$raw"
  local out=()
  local p
  for p in "${parts[@]}"; do
    p="${p// /}"
    case "$p" in
      mon*|m) out+=("Mon") ;;
      tue*|tu) out+=("Tue") ;;
      wed*|w) out+=("Wed") ;;
      thu*|th) out+=("Thu") ;;
      fri*|f) out+=("Fri") ;;
      sat*|s) out+=("Sat") ;;
      sun*|su) out+=("Sun") ;;
      *) ;; # ignore unknown
    esac
  done
  # de-duplicate preserving order
  local seen=()
  local out2=()
  for p in "${out[@]}"; do
    if [[ -z "${seen[$p]:-}" ]]; then
      seen[$p]=1
      out2+=("$p")
    fi
  done
  printf '%s\n' "${out2[@]}" | paste -sd' ' -
  return 0
}

# Run the zenity UI and write config. Returns:
# 0 on success (config written)
# 1 if user cancelled/closed
# 2 if bad usage (no cfg path)
# 3 if zenity missing
run_zenity_ui() {
  local CFG_PATH="${1:-}"
  if [[ -z "$CFG_PATH" ]]; then
    return 2
  fi
  if ! zenity_check; then
    return 3
  fi

  local status MEETING_ID PSK DAYS d t SCHEDULE_MAP parsed_days

  MEETING_ID=$(zenity --entry --title="Boom — Meeting ID" --text="Enter Meeting ID:" --entry-text "")
  status=$?
  if (( status != 0 )); then return 1; fi
  MEETING_ID="${MEETING_ID//[$'\r\n']}"       # strip newlines
  if [[ -z "$MEETING_ID" ]]; then
    zenity --error --title="Boom" --text="Meeting ID required"
    return 1
  fi

  PSK=$(zenity --password --title="Boom — Passcode" --text="Enter Passcode (PSK):")
  status=$?
  if (( status != 0 )); then return 1; fi
  PSK="${PSK//[$'\r\n']}"

  DAYS=$(zenity --entry --title="Boom — Days" --text="Days (comma-separated or 'every', e.g. mon,wed):" --entry-text "every")
  status=$?
  if (( status != 0 )); then return 1; fi
  DAYS="${DAYS//[$'\r\n']}"
  if [[ -z "$DAYS" ]]; then DAYS="every"; fi

  parsed_days="$(zenity_parse_days "$DAYS")"
  if [[ -z "$parsed_days" ]]; then
    zenity --error --title="Boom" --text="No valid days selected"
    return 1
  fi

  SCHEDULE_MAP=""
  for d in $parsed_days; do
    while true; do
      t=$(zenity --entry --title="Time for $d" --text="Enter time for $d (HH:MM 24h):" --entry-text "09:00")
      status=$?
      if (( status != 0 )); then
        return 1
      fi
      t="${t//[$'\r\n']}"
      if [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        SCHEDULE_MAP+="${SCHEDULE_MAP:+,}${d}=${t}"
        break
      else
        zenity --error --title="Boom" --text="Invalid time format for $d. Use HH:MM (24-hour)."
        # loop re-prompts; closing error dialog returns to time prompt, closing time prompt cancels overall
      fi
    done
  done

  mkdir -p "$(dirname "$CFG_PATH")"
  umask 177
  {
    printf 'MEETING_ID=%s\n' "$MEETING_ID"
    printf 'PSK=%s\n' "$PSK"
    printf 'SCHEDULE_DAYS=%s\n' "$DAYS"
    printf 'SCHEDULE_MAP=%s\n' "$SCHEDULE_MAP"
  } > "$CFG_PATH"
  chmod 600 "$CFG_PATH"

  zenity --info --title="Boom" --text="Saved to $CFG_PATH"
  return 0
}

# Provide a short alias name when sourced
zenity_helpers_available() { zenity_check; return $?; }

# END of