# Boom

Boom is a small tool to auto-join Zoom meetings on a schedule, provide HDMI‑CEC remote control and keep the meeting fullscreen.

See docs/USAGE.md for usage. Use the GUI with zenity (ui/gui.sh) or run headless with scheduler/systemd.

## Features

- **Automated Joining**: Automatically join Zoom meetings using saved configurations.
- **Configuration Management**: Easily configure meeting details, including meeting ID and passcode.
- **Scheduling**: Schedule meetings to join at specified times and days.
- **Graphical User Interface**: User-friendly GUI for input and interaction.
- **Fullscreen Support**: Ensures Zoom runs in fullscreen mode for an immersive experience.

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

3. (Optional) Set up the systemd service for automatic management:
   ```
   sudo cp systemd/boom.service /etc/systemd/system/
   sudo systemctl enable boom.service
   ```

4. Configure your meeting details:
   - Copy the example configuration file:
     ```
     cp config/meeting.conf.example config/meeting.conf
     ```
   - Edit `config/meeting.conf` to add your meeting ID, passcode, and schedule.

## Usage

- To join a meeting immediately using saved values:
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

- To run the scheduler loop:
  ```
  ./boom.sh --scheduler
  ```

## Contributing

Contributions are welcome! Please submit a pull request or open an issue for any enhancements or bug fixes.

## License

This project is licensed under the MIT License. See the LICENSE file for more details.