#!/usr/bin/env bash
# Boom — Automated Zoom Meeting Manager
# Single-file controller. Uses helpers under ui/ and scripts/ for GUI and fullscreen.
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boom"
CONFIG_FILE="$CONFIG_DIR/meeting.conf"
FS_HELPER="$PWD/scripts/fullscreen_helper.sh"
UI_SCRIPT="$PWD/ui/gui.sh"

LEFT_MEETING=0
CEC_MON_PID=""
FS_PID=""

# Load config if present
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  umask 177
  cat > "$CONFIG_FILE" <<EOF
MEETING_ID=${MEETING_ID:-}
PSK=${PSK:-}
SCHEDULE_DAYS=${SCHEDULE_DAYS:-}
SCHEDULE_MAP=${SCHEDULE_MAP:-}
EOF
  chmod 600 "$CONFIG_FILE"
  echo "Saved $CONFIG_FILE"
}

prompt_cli_details() {
  echo "Enter Zoom meeting details."
  read -rp "Meeting ID: " MEETING_ID
  read -rsp "Passcode (PSK): " PSK
  echo
  echo "Days (comma-separated or 'every'). Allowed: mon,tue,wed,thu,fri,sat,sun"
  read -rp "Days: " SCHEDULE_DAYS
  SCHEDULE_DAYS="${SCHEDULE_DAYS:-every}"
  SCHEDULE_MAP=""
  days_list="$(parse_days_input "$SCHEDULE_DAYS")"
  for d in $days_list; do
    while true; do
      read -rp "Time for $d (HH:MM 24h): " t
      if [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        SCHEDULE_MAP+="${SCHEDULE_MAP:+,}${d}=${t}"
        break
      fi
      echo "Invalid time."
    done
  done
  save_config
}

prompt_for_details() {
  load_config
  if command -v zenity >/dev/null 2>&1 && [[ "${1:-}" != "--no-gui" ]]; then
    if [[ -x "$UI_SCRIPT" ]]; then
      # Run GUI; if user cancels or closes, exit the whole program immediately.
      if "$UI_SCRIPT" "$CONFIG_FILE"; then
        load_config
        return
      else
        echo "GUI cancelled — exiting."
        exit 0
      fi
    fi
  fi
  prompt_cli_details
}

url_encode() {
  local raw="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$raw"
  else
    printf '%s' "$raw" | sed -e 's/ /%20/g' -e 's/+/%2B/g' -e 's/&/%26/g' -e "s/#/%23/g"
  fi
}

open_meeting_urls() {
  local zoom_uri="$1" https_url="$2"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$zoom_uri" >/dev/null 2>&1 || xdg-open "$https_url" >/dev/null 2>&1 &
  elif command -v gio >/dev/null 2>&1; then
    gio open "$zoom_uri" >/dev/null 2>&1 || gio open "$https_url" >/dev/null 2>&1 &
  else
    echo "Open manually: $zoom_uri or $https_url"
    return 1
  fi
  return 0
}

# send X keyboard events to Zoom/browser windows using xdotool
send_keys_to_zoom() {
  local keys="$1"
  if ! command -v xdotool >/dev/null 2>&1; then
    return 1
  fi
  local win
  win=$(xdotool search --onlyvisible --name "Zoom" 2>/dev/null | head -n1 || true)
  if [[ -z "$win" ]]; then
    win=$(xdotool search --onlyvisible --name "zoom.us" 2>/dev/null | head -n1 || true)
  fi
  if [[ -z "$win" ]]; then
    win=$(xdotool search --onlyvisible --name "zoom" 2>/dev/null | head -n1 || true)
  fi
  if [[ -n "$win" ]]; then
    xdotool windowactivate --sync "$win"
    xdotool key --delay 80 $keys || true
    return 0
  fi
  return 1
}

action_toggle_mic()    { send_keys_to_zoom "Alt+a"; }
action_toggle_video()  { send_keys_to_zoom "Alt+v"; }
action_leave_shortcut() { send_keys_to_zoom "Alt+q"; }
action_toggle_fullscreen() { send_keys_to_zoom "F11"; }

# Try to close Zoom/browser tabs
leave_meeting() {
  local zoom_uri="$1" https_url="$2"
  LEFT_MEETING=1
  stop_fullscreen_helper
  # Try xdotool to send Alt+Q (Zoom quit)
  send_keys_to_zoom "Alt+q" || true
  sleep 1
  # Try to pkill Zoom processes
  if pgrep -fi '(^|/)(zoom|zoom-us|Zoom)$' >/dev/null 2>&1; then
    pkill -15 -fi 'zoom' || true
    sleep 1
    pkill -9 -fi 'zoom' || true
    echo "Signaled Zoom processes."
    return 0
  fi
  # Try to close browser tabs opened with zoom url
  if pgrep -f 'zoom.us/j/' >/dev/null 2>&1; then
    pkill -15 -f 'zoom.us/j/' || true
    echo "Signaled browser processes with Zoom URL."
    return 0
  fi
  echo "No Zoom process found."
}

# Fullscreen helper: keep active window fullscreen using wmctrl or xdotool
start_fullscreen_helper() {
  if [[ -x "$FS_HELPER" ]]; then
    "$FS_HELPER" >/dev/null 2>&1 &
    FS_PID=$!
  else
    # fallback: try to set fullscreen once
    if command -v wmctrl >/dev/null 2>&1; then
      wmctrl -r :ACTIVE: -b add,fullscreen >/dev/null 2>&1 || true
    else
      send_keys_to_zoom "F11" || true
    fi
  fi
}

stop_fullscreen_helper() {
  if [[ -n "${FS_PID:-}" ]]; then
    kill "$FS_PID" 2>/dev/null || true
    wait "$FS_PID" 2>/dev/null || true
    FS_PID=""
  fi
}

# HDMI-CEC monitor
start_cec_monitor() {
  local zuri="$1" hurl="$2"
  if [[ "${BOOM_DISABLE_CEC:-0}" == "1" ]]; then return 0; fi
  if ! command -v cec-client >/dev/null 2>&1; then return 0; fi
  cec-client -d 1 -m 1 2>&1 | while IFS= read -r line; do
    l="$line"
    if [[ "$l" =~ (KEY_[A-Z0-9_]+) ]]; then
      keyname="${BASH_REMATCH[1]}"
    else
      keyname=""
    fi
    case "$keyname" in
      KEY_EXIT|KEY_HOME|KEY_BACK|KEY_STOP|KEY_POWER)
        echo "CEC: exit-like ($keyname) -> leaving"
        leave_meeting "$zuri" "$hurl"
        break
        ;;
      KEY_MUTE)
        action_toggle_mic
        ;;
      KEY_VOLUMEUP)
        pactl set-sink-volume @DEFAULT_SINK@ +5% >/dev/null 2>&1 || true
        ;;
      KEY_VOLUMEDOWN)
        pactl set-sink-volume @DEFAULT_SINK@ -5% >/dev/null 2>&1 || true
        ;;
      KEY_PLAY|KEY_SELECT|KEY_OK|KEY_ENTER)
        open_meeting_urls "$zuri" "$hurl" >/dev/null 2>&1 || send_keys_to_zoom "Return"
        ;;
      KEY_INFO|KEY_HELP)
        echo "Status: Meeting=${MEETING_ID:-<unset>} Schedule=${SCHEDULE_MAP:-<unset>}"
        ;;
      KEY_RED|KEY_GREEN|KEY_YELLOW|KEY_BLUE)
        action_toggle_fullscreen
        ;;
      *)
        if [[ "${BOOM_CEC_DEBUG:-0}" == "1" ]]; then
          echo "CEC: $l"
        fi
        ;;
    esac
  done &
  CEC_MON_PID=$!
  trap '[[ -n "${CEC_MON_PID:-}" ]] && kill "${CEC_MON_PID}" 2>/dev/null || true' EXIT INT TERM
}

stop_cec_monitor() {
  if [[ -n "${CEC_MON_PID:-}" ]]; then
    kill "${CEC_MON_PID}" 2>/dev/null || true
    wait "${CEC_MON_PID}" 2>/dev/null || true
    unset CEC_MON_PID
  fi
}

# Helpers for schedule parsing and next timestamp
parse_days_input() {
  local raw="$1"
  local -a out=()
  raw="${raw,,}"
  if [[ "$raw" == "every" ]]; then
    echo "Mon Tue Wed Thu Fri Sat Sun"
    return
  fi
  IFS=',' read -r -a parts <<< "$raw"
  for token in "${parts[@]}"; do
    token="${token// /}"
    case "$token" in
      mon*|m) out+=("Mon") ;;
      tue*|tu) out+=("Tue") ;;
      wed*|w) out+=("Wed") ;;
      thu*|th) out+=("Thu") ;;
      fri*|f) out+=("Fri") ;;
      sat*|s) out+=("Sat") ;;
      sun*|su) out+=("Sun") ;;
    esac
  done
  # uniq
  echo "${out[@]}" | awk '{
    for(i=1;i<=NF;i++) if(!seen[$i]++){ printf "%s%s",$i,(i==NF?RS:OFS) }
  }' OFS=' ' RS='\n'
}

get_time_for_day() {
  local day="$1"
  local map="${SCHEDULE_MAP:-}"
  [[ -z "$map" ]] && return 1
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

next_ts_for_day() {
  local day="$1" time="$2"
  local now today_day today_ts ts
  now=$(date +%s)
  today_day=$(date +%a)
  if [[ "$today_day" == "$day" ]]; then
    if today_ts=$(date -d "today $time" +%s 2>/dev/null); then
      if (( today_ts > now )); then
        echo "$today_ts"
        return
      fi
    fi
  fi
  ts=$(date -d "next $day $time" +%s 2>/dev/null || true)
  echo "$ts"
}

run_meeting_session() {
  local zoom_uri="$1" https_url="$2"
  LEFT_MEETING=0
  open_meeting_urls "$zoom_uri" "$https_url"
  sleep 2
  start_fullscreen_helper
  if [[ "${BOOM_DISABLE_CEC:-0}" != "1" ]]; then
    start_cec_monitor "$zoom_uri" "$https_url"
  fi
  echo "Meeting launched. ESC to leave, q to quit helper."
  trap 'stty sane >/dev/null 2>&1 || true; stop_cec_monitor; stop_fullscreen_helper' EXIT INT TERM
  while true; do
    if [[ "${LEFT_MEETING}" -eq 1 ]]; then break; fi
    if IFS= read -rsn1 -t 1 key; then
      if [[ $key == $'\x1b' ]]; then
        echo "Leaving..."
        leave_meeting "$zoom_uri" "$https_url"
        break
      fi
      if [[ $key == 'q' ]]; then
        echo "Quit requested."
        break
      fi
    fi
  done
  stop_cec_monitor
  stop_fullscreen_helper
  LEFT_MEETING=0
}

join_now() {
  load_config
  if [[ -z "${MEETING_ID:-}" || -z "${PSK:-}" ]]; then
    prompt_for_details "${1:-}"
    load_config
  fi
  local enc_psk zoom_uri https_url
  enc_psk="$(url_encode "$PSK")"
  zoom_uri="zoommtg://zoom.us/join?confno=${MEETING_ID}&pwd=${enc_psk}"
  https_url="https://zoom.us/j/${MEETING_ID}?pwd=${enc_psk}"
  run_meeting_session "$zoom_uri" "$https_url"
}

schedule_join_loop() {
  load_config
  if [[ -z "${MEETING_ID:-}" || -z "${PSK:-}" || -z "${SCHEDULE_MAP:-}" ]]; then
    echo "Missing configuration; run without --scheduler to configure."
    exit 1
  fi
  local days_str enc_psk zoom_uri https_url next_ts min_ts delta now day time_for_day
  days_str="$(parse_days_input "$SCHEDULE_DAYS")"
  enc_psk="$(url_encode "$PSK")"
  zoom_uri="zoommtg://zoom.us/join?confno=${MEETING_ID}&pwd=${enc_psk}"
  https_url="https://zoom.us/j/${MEETING_ID}?pwd=${enc_psk}"
  echo "Scheduler running. Days: $days_str"
  while true; do
    min_ts=""
    for day in $days_str; do
      time_for_day="$(get_time_for_day "$day" || true)"
      [[ -z "$time_for_day" ]] && continue
      next_ts=$(next_ts_for_day "$day" "$time_for_day" || true)
      [[ -z "$next_ts" ]] && continue
      if [[ -z "$min_ts" || "$next_ts" -lt "$min_ts" ]]; then min_ts="$next_ts"; fi
    done
    if [[ -z "$min_ts" ]]; then sleep 60; continue; fi
    now=$(date +%s)
    delta=$((min_ts - now))
    if (( delta <= 0 )); then
      echo "Joining scheduled meeting now."
      run_meeting_session "$zoom_uri" "$https_url"
      continue
    fi
    echo "Next join at $(date -d "@$min_ts")"
    # sleep in chunks
    while (( delta > 0 )); do
      if (( delta > 3600 )); then sleep 3600; delta=$((delta-3600))
      elif (( delta > 60 )); then sleep 60; delta=$((delta-60))
      else sleep "$delta"; delta=0; fi
    done
  done
}

reset_config_interactive() {
  rm -f "$CONFIG_FILE" && echo "Config removed."
  prompt_for_details
}

edit_config() {
  load_config
  if command -v zenity >/dev/null 2>&1 && [[ "${1:-}" != "--no-gui" ]]; then
    if [[ -x "$UI_SCRIPT" ]]; then
      # If GUI returns non-zero (cancel/close), exit immediately.
      if "$UI_SCRIPT" "$CONFIG_FILE"; then
        # GUI saved/edited config, reload and return to caller
        load_config
        return
      else
        echo "GUI cancelled — exiting."
        exit 0
      fi
    fi
  fi
  echo "Edit CLI:"
  read -rp "Meeting ID (${MEETING_ID:-}): " new
  [[ -n "$new" ]] && MEETING_ID="$new"
  read -rsp "PSK (leave empty to keep): " newpsk; echo
  [[ -n "$newpsk" ]] && PSK="$newpsk"
  echo "Current map: ${SCHEDULE_MAP:-}"
  read -rp "Edit schedule? (y/N): " yn
  if [[ "${yn,,}" == "y" ]]; then
    SCHEDULE_MAP=""
    days_list="$(parse_days_input "${SCHEDULE_DAYS:-every}")"
    for d in $days_list; do
      read -rp "Time for $d: " t
      SCHEDULE_MAP+="${SCHEDULE_MAP:+,}${d}=${t}"
    done
  fi
  save_config
}

show_help() {
  sed -n '1,240p' "$0"
  cat <<'EOF'
Options:
  --gui          Open GUI to configure (requires zenity)
  --edit         Edit saved config
  --reset        Remove saved config and reconfigure
  --forget       Remove saved config
  --scheduler    Run scheduler loop
  --no-cec       Disable HDMI-CEC monitoring
  --help         Show this help
EOF
}

# CLI dispatch
case "${1:-}" in
  --forget)
    rm -f "$CONFIG_FILE" && echo "Removed config."
    exit 0
    ;;
  --reset)
    reset_config_interactive
    ;;
  --edit)
    edit_config
    exit 0
    ;;
  --gui)
    # Open GUI only and exit. If GUI cancelled, exit quietly.
    if command -v zenity >/dev/null 2>&1 && [[ -x "$UI_SCRIPT" ]]; then
      if "$UI_SCRIPT" "$CONFIG_FILE"; then
        echo "Configuration saved."
        exit 0
      else
        echo "GUI cancelled — exiting."
        exit 0
      fi
    else
      echo "Zenity/UI not available."
      exit 1
    fi
    ;;
  --scheduler)
    schedule_join_loop
    ;;
  --no-cec)
    export BOOM_DISABLE_CEC=1
    shift || true
    exec "$0" "$@"
    ;;
  --help|-h)
    show_help
    exit 0
    ;;
  "")
    join_now
    ;;
  *)
    echo "Unknown option. Use --help"
    exit 1
    ;;
esac