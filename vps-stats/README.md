# VPS Stats

CPU, RAM, disk, swap, load averages, uptime, network traffic, inodes, and process count for a Linux VPS. Uses your existing **ovh** SSH alias by default, verified as **ns507318**.

- A compact bottom-bar summary shows CPU, RAM and disk use with matching color accents. Hover for a native glass panel with usage meters, recent activity, bandwidth, uptime, load and swap; click to refresh.
- Open **VPS Stats** in Zeron's sidebar for the detailed view and recent CPU/RAM/disk chart.
- **Settings → VPS Stats** changes the SSH host, disk path, polling interval, and whether the bottom-bar summary shows.

Samples every 10 seconds while Zeron is visible, with at most one SSH request in flight. The chart keeps the latest 120 samples in memory. Connection failures retain the last sample and clearly mark it as stale. No sounds or notifications.

The collector is sent on standard input to `python3 -` over SSH, reads Linux `/proc` and filesystem statistics, and exits. It installs nothing, saves nothing on the server, uses no sudo, does not change server configuration, and does not forward your SSH agent. Python 3 must already be installed on the server. SSH key checking remains enabled; new or changed host keys are never accepted automatically.

CPU is normalized across all vCPUs using a short two-sample measurement. RAM uses MemAvailable to exclude reclaimable cache. Disk percentage follows df's available-space convention, and network rates use the default interface rather than adding virtual interfaces together.

Permissions: `ui.add`, `pages.add`, and `commands` limited to the named `ssh` executable. Zeron asks you to approve the plugin before it runs.
