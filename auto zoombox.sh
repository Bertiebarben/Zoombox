#!/usr/bin/env bash
# Simple Zoom joiner: stores meeting ID, passcode (psk) and schedule on first run.
# Usage:
#   ./zoombox.sh                # join immediately using saved values (asks on first run)
#   ./zoombox.sh --edit         # change saved values
#   ./zoombox.sh --forget       # remove saved config
#   ./zoombox.sh --reset        # reset and reconfigure meeting details + schedule
#   ./zoombox.sh --no-cec       # disable HDMI-CEC monitoring
#   ./zoombox.sh --scheduler    # run scheduler loop (joins at configured day/time)

set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zoombox"
CONFIG_FILE="$CONFIG_DIR/meeting.conf"

# global flag set when leave_meeting was invoked
LEFT_MEETING=0
CEC_MON_PID=""

prompt_for_details() {
  echo "Zoom meeting details not found — please enter them."
  read -rp "Meeting ID: " MEETING_ID
  # hide passcode input
  read -rsp "Passcode (PSK): " PSK
  echo

  # Ask schedule (day(s) and time)
  echo "When should this auto-join? Enter days (comma-separated) or 'every'. Allowed values: mon,tue,wed,thu,fri,sat,sun or every"
  read -rp "Days (e.g. mon,wed,fri or every): " SCHEDULE_DAYS
  SCHEDULE_DAYS="${SCHEDULE_DAYS:-every}"

  # Build mapping of day->time (SCHEDULE_MAP format: Mon=HH:MM,Wed=HH:MM,...)
  SCHEDULE_MAP=""
  # parse_days_input is defined later but callable
  days_list="$(parse_days_input "$SCHEDULE_DAYS")"
  for d in $days_list; do
    while true; do
      read -rp "Time for $d (24h HH:MM): " t
      if [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        if [[ -n "$SCHEDULE_MAP" ]]; then
          SCHEDULE_MAP+=",${d}=${t}"
        else
          SCHEDULE_MAP+="${d}=${t}"
        fi
        break
      fi
      echo "Invalid time format. Use HH:MM (24-hour)."
    done
  done

  save_config
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  umask 177
  cat > "$CONFIG_FILE" <<EOF
MEETING_ID=${MEETING_ID}
PSK=${PSK}
SCHEDULE_DAYS=${SCHEDULE_DAYS}
SCHEDULE_MAP=${SCHEDULE_MAP}
EOF
  chmod 600 "$CONFIG_FILE"
  echo "Saved to $CONFIG_FILE"
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

forget_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    rm -f "$CONFIG_FILE" && echo "Removed $CONFIG_FILE"
  else
    echo "No saved config to remove."
  fi
  exit 0
}

reset_config_interactive() {
  # remove existing config then prompt again
  if [[ -f "$CONFIG_FILE" ]]; then
    rm -f "$CONFIG_FILE"
    echo "Existing configuration removed."
  fi
  prompt_for_details
  exit 0
}

edit_config() {
  load_config
  echo "Current Meeting ID: ${MEETING_ID:-<not set>}"
  read -rp "New Meeting ID (leave empty to keep): " new_id
  if [[ -n "$new_id" ]]; then
    MEETING_ID="$new_id"
  fi
  echo "Current PSK: ${PSK:+(hidden)}"
  read -rsp "New PSK (leave empty to keep): " new_psk
  echo
  if [[ -n "$new_psk" ]]; then
    PSK="$new_psk"
  fi

  echo "Current schedule days: ${SCHEDULE_DAYS:-every}"
  read -rp "New days (leave empty to keep): " new_days
  if [[ -n "$new_days" ]]; then
    SCHEDULE_DAYS="$new_days"
    # rebuild map for new selection
    SCHEDULE_MAP=""
    days_list="$(parse_days_input "$SCHEDULE_DAYS")"
    for d in $days_list; do
      # try to preserve existing time for day if present
      existing_time="$(get_time_for_day "$d" || true)"
      while true; do
        if [[ -n "$existing_time" ]]; then
          read -rp "Time for $d (leave empty to keep $existing_time): " t
          if [[ -z "$t" ]]; then
            t="$existing_time"
          fi
        else
          read -rp "Time for $d (HH:MM): " t
        fi
        if [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
          if [[ -n "$SCHEDULE_MAP" ]]; then
            SCHEDULE_MAP+=",${d}=${t}"
          else
            SCHEDULE_MAP+="${d}=${t}"
          fi
          break
        fi
        echo "Invalid time format. Use HH:MM (24-hour)."
      done
    done
  else
    # allow editing times for currently configured days
    echo "Current schedule mapping: ${SCHEDULE_MAP:-<not set>}"
    read -rp "Edit times? (y/N): " edit_times
    if [[ "${edit_times,,}" == "y" || "${edit_times,,}" == "yes" ]]; then
      # rebuild SCHEDULE_MAP by prompting for each day currently present in SCHEDULE_MAP
      old_map="${SCHEDULE_MAP:-}"
      SCHEDULE_MAP=""
      IFS=',' read -r -a pairs <<< "$old_map"
      for p in "${pairs[@]}"; do
        day="${p%%=*}"
        cur="${p#*=}"
        while true; do
          read -rp "Time for $day (leave empty to keep $cur): " t
          if [[ -z "$t" ]]; then
            t="$cur"
          fi
          if [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            if [[ -n "$SCHEDULE_MAP" ]]; then
              SCHEDULE_MAP+=",${day}=${t}"
            else
              SCHEDULE_MAP+="${day}=${t}"
            fi
            break
          fi
          echo "Invalid time format. Use HH:MM (24-hour)."
        done
      done
    fi
  fi

  save_config
  exit 0
}

url_encode() {
  local raw="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$raw"
  else
    printf '%s' "$raw" | sed -e 's/ /%20/g' -e 's/+/%2B/g' -e 's/&/%26/g' -e "s/#/%23/g"
  fi
}

# Attempt to leave/close Zoom. Tries xdotool -> pkill zoom client -> pkill browser tabs with zoom url.
leave_meeting() {
  local zoom_uri="$1" https_url="$2"
  LEFT_MEETING=1

  # Try xdotool (close Zoom window if present)
  if command -v xdotool >/dev/null 2>&1; then
    local win
    win=$(xdotool search --onlyvisible --name "Zoom" 2>/dev/null | head -n1 || true)
    if [[ -n "$win" ]]; then
      xdotool windowactivate "$win" key --delay 100 Alt+F4 2>/dev/null || true
      sleep 1
    fi
  fi

  # Try to terminate Zoom client process(es)
  if pgrep -fi '(^|/)(zoom|zoom-us|Zoom)$' >/dev/null 2>&1 || pgrep -fi 'zoom' >/dev/null 2>&1; then
    pkill -15 -fi 'zoom' || true
    sleep 1
    if pgrep -fi 'zoom' >/dev/null 2>&1; then
      pkill -9 -fi 'zoom' || true
    fi
    echo "Signaled Zoom client processes to stop."
    return 0
  fi

  # Try to close browser processes that opened a zoom URL
  if pgrep -f 'zoom.us/j/' >/dev/null 2>&1; then
    pkill -15 -f 'zoom.us/j/' || true
    echo "Signaled browser processes with Zoom URL to stop."
    return 0
  fi

  echo "Couldn't detect a Zoom process to close. Close it manually."
}

# Start a background HDMI-CEC monitor (uses cec-client) to listen for remote keys.
start_cec_monitor() {
  local zuri="$1" hurl="$2"
  if [[ "${ZOOBOX_DISABLE_CEC:-0}" == "1" ]]; then
    return 0
  fi
  if ! command -v cec-client >/dev/null 2>&1; then
    return 0
  fi

  cec-client -d 1 -m 1 2>&1 | while IFS= read -r line; do
    l="$line"
    if [[ "$l" =~ KEY_EXIT|KEY_HOME|KEY_BACK|KEY_STOP|KEY_POWER ]]; then
      echo "CEC: detected exit key: $l"
      leave_meeting "$zuri" "$hurl"
      break
    fi
  done &
  CEC_MON_PID=$!
  trap '[[ -n "${CEC_MON_PID:-}" ]] && kill "${CEC_MON_PID}" 2>/dev/null || true' EXIT INT TERM
  echo "CEC monitor started (pid=${CEC_MON_PID})."
}

stop_cec_monitor() {
  if [[ -n "${CEC_MON_PID:-}" ]]; then
    kill "${CEC_MON_PID}" 2>/dev/null || true
    wait "${CEC_MON_PID}" 2>/dev/null || true
    unset CEC_MON_PID
  fi
}

# utility: get time for a given day from SCHEDULE_MAP
get_time_for_day() {
  local day="$1"
  local map="${SCHEDULE_MAP:-}"
  if [[ -z "$map" ]]; then
    return 1
  fi
  IFS=',' read -r -a pairs <<< "$map"
  for p in "${pairs[@]}"; do
    key="${p%%=*}"
    val="${p#*=}"
    if [[ "$key" == "$day" ]]; then
      echo "$val"
      return 0
    fi
  done
  return 1
}

# open the meeting URL(s) but don't re-prompt for details
open_meeting_urls() {
  local zoom_uri="$1" https_url="$2"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$zoom_uri" >/dev/null 2>&1 || xdg-open "$https_url" >/dev/null 2>&1 &
  elif command -v gio >/dev/null 2>&1; then
    gio open "$zoom_uri" >/dev/null 2>&1 || gio open "$https_url" >/dev/null 2>&1 &
  else
    echo "No xdg-open/gio found. Open this URL manually:"
    echo "$zoom_uri"
    echo "$https_url"
    return 1
  fi
  return 0
}

# runs a meeting session: opens URLs, starts CEC monitor and keyboard monitor until leave
run_meeting_session() {
  local zoom_uri="$1" https_url="$2"
  LEFT_MEETING=0

  open_meeting_urls "$zoom_uri" "$https_url" || return 1

  # Start CEC monitor (if available and not disabled)
  if [[ "${ZOOBOX_DISABLE_CEC:-0}" != "1" ]]; then
    start_cec_monitor "$zoom_uri" "$https_url"
  fi

  echo "Meeting launched. Press ESC to leave from this terminal, or use HDMI-CEC remote."
  trap 'stty sane >/dev/null 2>&1 || true; stop_cec_monitor' EXIT INT TERM

  # keyboard monitor: wait for ESC or q or leave signaled by CEC
  while true; do
    # break if CEC signaled leave
    if [[ "${LEFT_MEETING}" -eq 1 ]]; then
      break
    fi
    # non-blocking read with timeout to allow loop to check LEFT_MEETING
    if IFS= read -rsn1 -t 1 key; then
      if [[ $key == $'\x1b' ]]; then
        echo
        echo "Leaving meeting..."
        leave_meeting "$zoom_uri" "$https_url"
        break
      fi
      if [[ $key == 'q' ]]; then
        echo
        echo "Quit requested."
        break
      fi
    fi
  done

  stop_cec_monitor
  LEFT_MEETING=0
}

join_now() {
  load_config
  if [[ -z "${MEETING_ID:-}" || -z "${PSK:-}" ]]; then
    prompt_for_details
  fi

  local enc_psk
  enc_psk="$(url_encode "$PSK")"
  local zoom_uri="zoommtg://zoom.us/join?confno=${MEETING_ID}&pwd=${enc_psk}"
  local https_url="https://zoom.us/j/${MEETING_ID}?pwd=${enc_psk}"

  run_meeting_session "$zoom_uri" "$https_url"
}

# Normalize user days input -> array of 3-letter Titlecase day names (Mon Tue ...)
parse_days_input() {
  local raw="$1"
  local -a out=()
  local token
  raw="${raw,,}" # lowercase
  if [[ "$raw" == "every" ]]; then
    echo "Mon Tue Wed Thu Fri Sat Sun"
    return 0
  fi
  IFS=',' read -r -a parts <<< "$raw"
  for token in "${parts[@]}"; do
    token="${token// /}"
    case "$token" in
      mon*|m) out+=("Mon") ;;
      tue*|tue|tu) out+=("Tue") ;;
      wed*|w) out+=("Wed") ;;
      thu*|th) out+=("Thu") ;;
      fri*|f) out+=("Fri") ;;
      sat*|s) out+=("Sat") ;;
      sun*|su) out+=("Sun") ;;
      *) ;; # ignore unknown
    esac
  done
  # remove duplicates
  echo "${out[@]}" | awk '{
    for(i=1;i<=NF;i++) if(!seen[$i]++){ printf "%s%s",$i,(i==NF?RS:OFS) }
  }' OFS=' ' RS='\n'
}

# compute next timestamp (epoch) for a given day (Mon..Sun) and time HH:MM
next_ts_for_day() {
  local day="$1" time="$2"
  local now ts today_day today_ts
  now=$(date +%s)
  today_day=$(date +%a)
  if [[ "$today_day" == "$day" ]]; then
    # try today at that time
    if today_ts=$(date -d "today $time" +%s 2>/dev/null); then
      if (( today_ts > now )); then
        echo "$today_ts"
        return 0
      fi
    fi
  fi
  # otherwise next <day>
  ts=$(date -d "next $day $time" +%s 2>/dev/null || true)
  echo "$ts"
}

# scheduler loop: calculates next occurrence and waits, then joins
schedule_join_loop() {
  load_config
  if [[ -z "${MEETING_ID:-}" || -z "${PSK:-}" || -z "${SCHEDULE_DAYS:-}" || -z "${SCHEDULE_MAP:-}" ]]; then
    echo "Missing configuration. Run without --scheduler to configure."
    exit 1
  fi

  local days_str day enc_psk zoom_uri https_url next_ts min_ts delta time_for_day
  days_str="$(parse_days_input "$SCHEDULE_DAYS")"
  enc_psk="$(url_encode "$PSK")"
  zoom_uri="zoommtg://zoom.us/join?confno=${MEETING_ID}&pwd=${enc_psk}"
  https_url="https://zoom.us/j/${MEETING_ID}?pwd=${enc_psk}"

  echo "Scheduler running. Days: $days_str"
  while true; do
    min_ts=""
    for day in $days_str; do
      time_for_day="$(get_time_for_day "$day" || true)"
      if [[ -z "$time_for_day" ]]; then
        # skip days without configured time
        continue
      fi
      next_ts=$(next_ts_for_day "$day" "$time_for_day" || true)
      if [[ -z "$next_ts" ]]; then
        continue
      fi
      if [[ -z "$min_ts" || "$next_ts" -lt "$min_ts" ]]; then
        min_ts="$next_ts"
      fi
    done

    if [[ -z "$min_ts" ]]; then
      echo "Could not compute next scheduled time. Sleeping 60s then retrying."
      sleep 60
      continue
    fi

    now=$(date +%s)
    delta=$((min_ts - now))
    if (( delta <= 0 )); then
      # time arrived or passed, join immediately
      echo "Time reached — joining meeting now."
      run_meeting_session "$zoom_uri" "$https_url"
      # after meeting ends, continue loop to compute next occurrence
      continue
    fi

    echo "Next join at $(date -d "@$min_ts") (in $delta seconds). Sleeping..."
    # sleep in chunks to be interruptible by signals
    while (( delta > 0 )); do
      if (( delta > 3600 )); then
        sleep 3600
        delta=$((delta - 3600))
      elif (( delta > 60 )); then
        sleep 60
        delta=$((delta - 60))
      else
        sleep "$delta"
        delta=0
      fi
      # if LEFT_MEETING was toggled externally or script signalled, will handle on wake
    done
    # loop continues to compute next occurrence (join will happen at or after sleep)
  done
}

# CLI
if [[ "${1:-}" == "--forget" ]]; then
  forget_config
elif [[ "${1:-}" == "--reset" ]]; then
  reset_config_interactive
elif [[ "${1:-}" == "--edit" ]]; then
  edit_config
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '1,240p' "$0"
  exit 0
else
  # allow explicit --no-cec to disable HDMI-CEC monitoring
  if [[ "${1:-}" == "--no-cec" ]]; then
    ZOOBOX_DISABLE_CEC=1
    shift || true
  fi
  case "${1:-}" in
    --scheduler|--run-scheduled)
      schedule_join_loop
      ;;
    --)
      join_now
      ;;
    "")
      # default: join now (prompts on first run)
      join_now
      ;;
    *)
      # unknown arg: show help
      echo "Unknown option: ${1:-}"
      echo "Use --help or -h for usage information."
      exit 1
      ;;
  esac
fi