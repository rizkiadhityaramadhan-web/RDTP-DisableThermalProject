# RizkiDisableThermalProject (RDTP)

Magisk / KernelSU Next module to disable the thermal throttling stack on **Poco F6 (Peridot, Snapdragon 8s Gen 3, Android 16)**.

- **Version:** v2.4
- **Author:** Rizki Adhitya ([TikTok: @kiistacy_](https://www.tiktok.com/@kiistacy_))
- **Compatibility:** KernelSU Next (≥ 11998) & Magisk (≥ 20400)

## ⚠️ Disclaimer

This module disables the device's thermal protection. Use at your own risk. Disabling thermal management can lead to overheating, battery degradation, or hardware damage if not monitored. An emergency kill-switch is included, but it is a software safeguard, not a substitute for proper cooling and common sense.

## Features

### Layer 1 — Property Override (`post-fs-data.sh`, `system.prop`)
Clears vendor thermal config properties (`vendor.thermal.config`, `persist.vendor.thermal.*`) via `resetprop`, and disables DFPS thermal-triggered refresh rate drops, PowerHAL thermal interaction, and framework thermal notifications.

### Layer 2 — Runtime sysfs Disable (`service.sh`)
Sets all `/sys/class/thermal/thermal_zone*/mode` to `disabled` at `late_start service`.

### Layer 3 — Service Kill + RC Override
Stops vendor thermal daemons (`thermal-engine`, `mi_thermald`, `android.hardware.thermal-service.qti`, etc.) and overrides their init `.rc` entries to `/system/vendor/bin/true`. Dummy binaries with `0000` permissions are injected for key vendor thermal executables.

### Layer 4 — Watchdog + Emergency Kill-Switch
A background loop (45s interval) re-disables thermal zones/services if the system re-enables them. If CPU temperature (CPU-only zones) reaches **≥ 80°C**, thermal protection is automatically re-enabled until temperature drops below **68°C** (10-minute timeout), then re-disabled.

### Layer 5 — Auto Governor / Game Performance Mode (new in v2.4)
Polls foreground app every 5 seconds via `dumpsys window`. When a configured game (`com.mobile.legends`, `com.tencent.ig`) is in foreground, sets CPU governor to `performance` on all clusters; reverts to `schedutil` otherwise. GPU governor is left untouched.

> **Note:** Layer 5 does not coordinate with the Layer 4 emergency kill-switch. If CPU hits 80°C while governor is `performance`, both mechanisms run independently — cooling to 68°C may be slower or may not complete within the 10-minute window. This is intentional; see [CHANGELOG.md](CHANGELOG.md) for details.

## Installation

1. Download the latest release zip.
2. Flash via Magisk or KernelSU Next Manager → Modules → Install from storage.
3. Reboot.

## Uninstallation

Use the manager's module removal, or run `uninstall.sh`, which re-enables all thermal zones and restarts thermal services before cleanup.

## Logs

- `/data/local/tmp/rdtp_thermal.log` — main service / watchdog log
- `/data/local/tmp/rdtp_thermal_postfs.log` — post-fs-data (Layer 1) log
- `/data/local/tmp/rdtp_governor.log` — Layer 5 governor log

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

## License

No license specified — all rights reserved by default. Add a `LICENSE` file if you want to permit reuse/redistribution.
