# LPMonitor_Restart

A lightweight macOS tool for automatically monitoring Imprivata GroundControl Launchpads and remotely triggering Workspace ONE (WS1) soft resets when issues are detected. Built for unattended use via LaunchAgent, it helps IT teams identify and remediate disconnected or idle Launchpads with minimal manual intervention.

---

## 📦 Package Contents

```
LPMonitor_Restart/
├── LPMonitor_Restart.sh                 # Main monitoring and reset script
├── Update LP List.sh                    # Retrieves device serial mappings from WS1
├── manage_gc_monitor.sh                 # CLI tool for controlling LaunchAgent
├── com.imprivata.groundcontrolmonitor.plist  # LaunchAgent to run the monitor script every 60s
├── logs/                                # Stores timestamped logs
├── .alerts/                             # Temporary flags for Launchpads in error
└── .alert_counts/                       # Tracks issue cooldowns and durations
```

---

## 🚀 Features

- Monitors all Launchpads registered to a configured account
- Checks:
  - Online status
  - Smart Hub (badge reader) presence
  - Docked device availability
- Uses Workspace ONE UEM API to issue soft reset commands
- Avoids duplicate actions with cooldown logic
- Token-based OAuth authentication and automatic caching
- Runs every 60 seconds via LaunchAgent

---

## ⚙️ Installation & Setup

1. **Place the Files**  
   Extract all files to a directory like `~/My_Scripts/LPMonitor_Restart`

2. **Install Dependencies**
   ```bash
   brew install jq
   # curl is built-in on macOS
   ```

3. **Make Scripts Executable**
   ```bash
   chmod +x ~/My_Scripts/LPMonitor_Restart/*.sh
   ```

4. **Install the LaunchAgent**
   ```bash
   cp com.imprivata.groundcontrolmonitor.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.imprivata.groundcontrolmonitor.plist
   ```

5. **Control LaunchAgent Manually** (optional)
   ```bash
   ./manage_gc_monitor.sh start   # or stop / status / restart
   ```

---

## 🔐 Authentication

This tool uses Workspace ONE UEM's OAuth flow. You must:
- Edit `LPMonitor_Restart.sh` to provide:
  - WS1 tenant URL
  - Client ID and secret (stored securely or as environment vars)
- A token is cached in `ws1_token_cache.json` and refreshed automatically every hour

---

## 📝 Logging

Log files are written to:
```
logs/YYYY-MM-DD_HH-MM-SS.log
```
Each run includes timestamped entries for each Launchpad's status, including actions taken (e.g. reset sent).

---

## 🧪 Testing the Script

Run manually:
```bash
bash ./LPMonitor_Restart.sh
```
You can also test the LaunchAgent cycle:
```bash
./manage_gc_monitor.sh restart
```

---

## 🧭 Flowchart

```
Start
  ↓
Query Imprivata GroundControl API
  ↓
Filter by target email address
  ↓
For each Launchpad:
  ├── Check online status
  ├── Check Smart Hub presence
  └── Check for docked devices
        ↓
    If unhealthy:
      ├── Check cooldown window
      └── Trigger WS1 soft reset
            ↓
          Log results and flag alerts
```

---

## 📄 License

This project is licensed under the MIT License. See `LICENSE` for details.

---

## 🙋 Support

For questions, suggestions, or contributions, feel free to open an issue or PR.
