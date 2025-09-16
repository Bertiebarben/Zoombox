#!/usr/bin/env bash

# Fullscreen Helper for Boom — Ensures Zoom runs in fullscreen mode

toggle_fullscreen() {
  # Check if Zoom is running
  if pgrep -x "zoom" > /dev/null; then
    # Send the fullscreen toggle key (F11)
    xdotool search --onlyvisible --name "Zoom" windowactivate --sync key F11
  else
    echo "Zoom is not running."
  fi
}

# Call the toggle_fullscreen function
toggle_fullscreen