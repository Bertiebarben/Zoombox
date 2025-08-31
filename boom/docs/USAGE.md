# USAGE Instructions for Zoombox

## Overview
Zoombox is a script-based application designed to automate the process of joining Zoom meetings. It allows users to save meeting configurations, schedule meetings, and control Zoom through keyboard shortcuts.

## Installation
1. Clone the repository:
   ```
   git clone <repository-url>
   cd zoombox
   ```

2. Make the main script executable:
   ```
   chmod +x bin/AutoBoom.sh
   ```

3. (Optional) Set up the systemd service for automatic execution:
   - Copy the `systemd/zoombox.service` file to `/etc/systemd/system/`.
   - Enable and start the service:
     ```
     sudo systemctl enable zoombox.service
     sudo systemctl start zoombox.service
     ```

## Usage
### Initial Setup
On the first run, execute the script to configure your meeting details:
```
./bin/AutoBoom.sh
```
You will be prompted to enter:
- Meeting ID
- Passcode (PSK)
- Schedule days and times

### Commands
- **Join Immediately**: 
  ```
  ./bin/AutoBoom.sh
  ```
  This will join the meeting using the saved configuration.

- **Edit Configuration**: 
  ```
  ./bin/AutoBoom.sh --edit
  ```
  Modify the saved meeting details.

- **Forget Configuration**: 
  ```
  ./bin/AutoBoom.sh --forget
  ```
  Remove the saved configuration.

- **Reset Configuration**: 
  ```
  ./bin/AutoBoom.sh --reset
  ```
  Remove existing configuration and prompt for new details.

- **Run Scheduler**: 
  ```
  ./bin/AutoBoom.sh --scheduler
  ```
  Automatically join meetings at the scheduled times.

### Fullscreen Mode
To ensure that Zoom runs in fullscreen mode, you can use the `fullscreen_helper.sh` script. This script can be executed alongside the main script or configured to run automatically when joining a meeting.

### Keyboard Shortcuts
While in a Zoom meeting, you can use the following keyboard shortcuts:
- **Toggle Microphone**: Alt + A
- **Toggle Video**: Alt + V
- **Leave Meeting**: Alt + Q
- **Fullscreen Toggle**: F

## Notes
- Ensure that you have the necessary permissions to run scripts and access Zoom.
- The application may require additional dependencies such as `xdotool` for keyboard automation.

For further assistance, refer to the README.md file or the documentation provided in this directory.