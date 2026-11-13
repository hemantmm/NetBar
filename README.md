# NetBar

NetBar is a small macOS menu bar network monitor. It shows live download and upload speeds, total network usage, and a per-process usage breakdown for today and the last seven days.

## Requirements

- macOS
- Bash
- The Swift runtime available from Xcode Command Line Tools

NetBar uses built-in macOS tools (`route`, `netstat`, and `nettop`) to read network counters. It does not send usage data to a server.

## Run

From the project folder:

```bash
chmod +x netbar.sh
./netbar.sh
```

The menu bar shows current download and upload speed. Click the item to see total usage. Click **Today** or **Last 7 days** to expand the per-process breakdown, sorted by data used.

To stop NetBar, choose **Quit NetBar** from its menu.

## Install from a hosted copy

After the script is published at a public GitHub repository, users can download and run it with:

```bash
curl -fLO https://raw.githubusercontent.com/OWNER/REPOSITORY/main/netbar.sh
chmod +x netbar.sh
./netbar.sh
```

Replace `OWNER` and `REPOSITORY` with the GitHub account and repository that host NetBar. Review downloaded scripts before running them.

## Usage data

NetBar stores its counters locally in:

```text
~/Library/Application Support/NetBar/
```

The **Today** and **Last 7 days** totals are cumulative byte counts, not averages. Interface totals use the active default network interface. Per-process totals are collected while NetBar is running; macOS may list helper processes separately from their parent app, and per-process totals may not exactly match interface totals.

## Troubleshooting

- If the menu says it is waiting for a network, check that macOS has an active default network connection.
- If the per-process submenu says data is unavailable, check that `/usr/bin/nettop` runs successfully from Terminal.
- After editing the script, quit the current NetBar instance and run `./netbar.sh` again to start the updated version.
