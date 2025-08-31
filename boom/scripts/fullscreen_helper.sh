#!/usr/bin/env bash
# Fullscreen Helper for Zoom

# Function to set Zoom to fullscreen
set_fullscreen() {
  local win
  win=$(xdotool search --onlyvisible --name "Zoom" 2>/dev/null | head -n1 || true)
  
  if [[ -n "$win" ]]; then
    xdotool windowactivate --sync "$win"
    xdotool key F
    echo "Zoom is now in fullscreen mode."
  else
    echo "No Zoom window found."
  fi
}

# Check if Zoom is running and set to fullscreen
if pgrep -fi 'zoom' >/dev/null 2>&1; then
  set_fullscreen
else
  echo "Zoom is not running."
fi