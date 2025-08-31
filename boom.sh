#!/usr/bin/env bash
# Boom — Automated Zoom Meeting Manager (formerly "ZoomBox")
# Usage:
#   ./boom.sh                # join immediately using saved values (asks on first run)
#   ./boom.sh --edit         # change saved values
#   ./boom.sh --forget       # remove saved config
#   ./boom.sh --reset        # reset and reconfigure meeting details + schedule
#   ./boom.sh --no-cec       # disable HDMI-CEC monitoring
#   ./boom.sh --scheduler    # run scheduler loop (joins at configured day/time)

set -euo pipefail

# config directory renamed for boom
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boom"
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

# helper: send key sequence to the Zoom window (or to the first browser window with a zoom URL)
send_keys_to_zoom() {
  local keys="$1"
  local win

  # try Zoom client window
  win=$(xdotool search --onlyvisible --name "Zoom" 2>/dev/null | head -n1 || true)
  if [[ -z "$win" ]]; then
    # try common Zoom window title patterns or browser tabs
    win=$(xdotool search --onlyvisible --name "zoom.us/j" 2>/dev/null | head -n1 || true)
  fi
  if [[ -z "$win" ]]; then
    # last resort: any window containing 'zoom' in name
    win=$(xdotool search --onlyvisible --name "zoom" 2>/dev/null | head -n1 || true)
  fi

  if [[ -n "$win" ]]; then
    xdotool windowactivate --sync "$win"
    # send the keys (xdotool format)
    xdotool key --delay 80 $keys || true
    return 0
  fi

  echo "No Zoom window found to send keys to."
  return 1
}

# convenience actions mapped to Zoom keyboard shortcuts or system controls
action_toggle_mic()    { send_keys_to_zoom "Alt+a"; }
action_toggle_video()  { send_keys_to_zoom "Alt+v"; }
action_leave_shortcut() { send_keys_to_zoom "Alt+q"; }
action_toggle_fullscreen() { send_keys_to_zoom "F"; }
action_press_enter()   { send_keys_to_zoom "Return"; }
action_arrow_up()      { send_keys_to_zoom "Up"; }
action_arrow_down()    { send_keys_to_zoom "Down"; }
action_arrow_left()    { send_keys_to_zoom "Left"; }
action_arrow_right()   { send_keys_to_zoom "Right"; }

# system audio controls (safe no-op if pactl missing)
audio_volume_up() {
  if command -v pactl >/dev/null 2>&1; then
    pactl set-sink-volume @DEFAULT_SINK@ +5% >/dev/null 2>&1 || true
  fi
}
audio_volume_down() {
  if command -v pactl >/dev/null 2>&1; then
    pactl set-sink-volume @DEFAULT_SINK@ -5% >/dev/null 2>&1 || true
  fi
}
audio_toggle_mute() {
  if command -v pactl >/dev/null 2>&1; then
    pactl set-sink-mute @DEFAULT_SINK@ toggle >/dev/null 2>&1 || true
  fi
}
mic_toggle_mute() {
  # toggle source mute if available (may not reflect Zoom mute state)
  if command -v pactl >/dev/null 2>&1; then
    pactl set-source-mute @DEFAULT_SOURCE@ toggle >/dev/null 2>&1 || true
  fi
}

# Start a background HDMI-CEC monitor (uses cec-client) to listen for remote keys.
# Extended mapping: many KEY_* events are mapped to useful actions.
start_cec_monitor() {
  local zuri="$1" hurl="$2"
  if [[ "${BOOM_DISABLE_CEC:-0}" == "1" ]]; then
    return 0
  fi
  if ! command -v cec-client >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v xdotool >/dev/null 2>&1; then
    echo "Warning: xdotool not found — CEC controls that send keys to Zoom will be limited."
  fi

  cec-client -d 1 -m 1 2>&1 | while IFS= read -r line; do
    l="$line"
    # Primary: match explicit KEY_* tokens (preferred)
    if [[ "$l" =~ (KEY_[A-Z0-9_]+) ]]; then
      keyname="${BASH_REMATCH[1]}"
    else
      keyname=""
    fi

    # If a hex keycode is presented like 'key pressed: 0x41', parse it (fallback)
    if [[ -z "$keyname" && "$l" =~ key\ pressed:\ 0x([0-9A-Fa-f]+) ]]; then
      hex="${BASH_REMATCH[1]}"
      # Map a couple of common hex codes — extend as needed for your remote
      case "${hex,,}" in
        0x44|44) keyname="KEY_PLAY" ;;     # example mapping
        0x46|46) keyname="KEY_STOP" ;;
        0x41|41) keyname="KEY_SELECT" ;;
        *) keyname="" ;;
      esac
    fi

    # dispatch actions based on keyname
    case "$keyname" in
      KEY_EXIT|KEY_HOME|KEY_BACK|KEY_STOP|KEY_POWER)
        echo "CEC: exit-like key ($keyname) detected — leaving meeting"
        leave_meeting "$zuri" "$hurl"
        break
        ;;
      KEY_PLAY|KEY_SELECT|KEY_OK|KEY_ENTER)
        echo "CEC: play/select — trying to open/join or press Enter"
        # if meeting not open, attempt to open; otherwise press Enter
        open_meeting_urls "$zuri" "$hurl" >/dev/null 2>&1 || action_press_enter
        ;;
      KEY_MUTE)
        echo "CEC: mute key — toggling Zoom mic (Alt+a) and system mic"
        action_toggle_mic
        mic_toggle_mute
        ;;
      KEY_VOLUMEUP)
        echo "CEC: volume up"
        audio_volume_up
        ;;
      KEY_VOLUMEDOWN)
        echo "CEC: volume down"
        audio_volume_down
        ;;
      KEY_REWIND|KEY_FASTREVERSE|KEY_LEFT)
        echo "CEC: rewind/left — sending Left arrow"
        action_arrow_left
        ;;
      KEY_FORWARD|KEY_FASTFORWARD|KEY_RIGHT)
        echo "CEC: forward/right — sending Right arrow"
        action_arrow_right
        ;;
      KEY_UP)
        echo "CEC: up"
        action_arrow_up
        ;;
      KEY_DOWN)
        echo "CEC: down"
        action_arrow_down
        ;;
      KEY_INFO|KEY_HELP)
        echo "CEC: info/help — printing status"
        # print a short status line to terminal
        echo "Status: Meeting=${MEETING_ID:-<unset>} Scheduled=${SCHEDULE_MAP:-<unset>}"
        ;;
      KEY_PLAY|KEY_PAUSE|KEY_PLAYPAUSE)
        echo "CEC: play/pause — toggling Zoom video (Alt+v)"
        action_toggle_video
        ;;
      KEY_RED|KEY_GREEN|KEY_YELLOW|KEY_BLUE)
        echo "CEC: color button pressed ($keyname) — toggling fullscreen"
        action_toggle_fullscreen
        ;;
      *) 
        # ignore unknown but print for debugging
        if [[ -n "$l" ]]; then
          # show only when debugging enabled
          if [[ "${BOOM_CEC_DEBUG:-0}" == "1" ]]; then
            echo "CEC: unhandled line: $l"
          fi
        fi
        ;;
    esac
  done &
  CEC_MON_PID=$!
  # ensure monitor killed on script exit
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
  if [[ "${BOOM_DISABLE_CEC:-0}" != "1" ]]; then
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
    BOOM_DISABLE_CEC=1
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