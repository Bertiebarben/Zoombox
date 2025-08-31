# Boom - Automated Zoom Meeting Manager

Boom automates joining Zoom meetings and provides HDMI‑CEC + keyboard controls.

## Usage (examples)

- To join a meeting immediately:
  ```
  ./boom.sh
  ```

- To edit saved configurations:
  ```
  ./boom.sh --edit
  ```

- To remove saved configurations:
  ```
  ./boom.sh --forget
  ```

- To reset and reconfigure meeting details:
  ```
  ./boom.sh --reset
  ```

- To run the scheduler loop for automatic joining:
  ```
  ./boom.sh --scheduler
  ```

If you keep the script inside a bin/ directory, adjust paths (e.g. ./bin/boom.sh). Update systemd unit names to refer to "boom" instead of "zoombox" if you set up a service.