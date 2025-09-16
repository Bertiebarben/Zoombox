# USAGE Instructions for Boom Application

## Overview
Boom is an automated Zoom meeting manager that simplifies the process of joining Zoom meetings. It allows users to configure meeting details, schedule automatic joins, and manage Zoom-related actions through a command-line interface or a graphical user interface (GUI).

## Installation
1. Clone the repository:
   ```
   git clone <repository-url>
   cd boom
   ```

2. Make the main script executable:
   ```
   chmod +x boom.sh
   ```

3. (Optional) Copy the example configuration file:
   ```
   cp config/meeting.conf.example config/meeting.conf
   ```

4. Edit the configuration file to include your Zoom meeting details.

## Usage
### Command-Line Interface
- To join a meeting immediately using saved values (prompts for details on first run):
  ```
  ./boom.sh
  ```

- To edit saved values:
  ```
  ./boom.sh --edit
  ```

- To remove saved configuration:
  ```
  ./boom.sh --forget
  ```

- To reset and reconfigure meeting details:
  ```
  ./boom.sh --reset
  ```

- To disable HDMI-CEC monitoring:
  ```
  ./boom.sh --no-cec
  ```

- To run the scheduler loop (joins at configured day/time):
  ```
  ./boom.sh --scheduler
  ```

### Graphical User Interface
To use the GUI, run the following command:
```
./ui/gui.sh
```
This will prompt you for the necessary meeting details through dialog boxes.

## Configuration
The configuration file (`config/meeting.conf`) contains the following parameters:
- `MEETING_ID`: Your Zoom meeting ID.
- `PSK`: The passcode for your Zoom meeting.
- `SCHEDULE_DAYS`: Days of the week to schedule automatic joins (e.g., `mon,wed,fri` or `every`).
- `SCHEDULE_MAP`: Mapping of days to times (e.g., `Mon=09:00,Wed=14:00`).

## Fullscreen Mode
To ensure Zoom runs in fullscreen mode, the application includes a helper script. You can configure this behavior in the `scripts/fullscreen_helper.sh` file.

## License
This project is licensed under the terms specified in the LICENSE file. Please review it for more information on usage and distribution rights.

# Boom Usage

- Run interactively:
  ./boom.sh           # prompts and joins now (first run will configure)
- Use GUI (requires zenity):
  ./boom.sh --gui
- Edit config:
  ./boom.sh --edit
- Reset config:
  ./boom.sh --reset
- Remove config:
  ./boom.sh --forget
- Scheduler (run in background or systemd):
  ./boom.sh --scheduler

HDMI-CEC:
- Requires cec-client. Remote keys mapped include Exit/Home/Back/Stop/Power to leave meeting.
- Color/Play/Mute/Volume keys map to useful actions.

Fullscreen:
- Uses wmctrl or xdotool to enforce fullscreen via scripts/fullscreen_helper.sh.

Notes:
- For full control install xdotool, wmctrl, cec-client, pactl.