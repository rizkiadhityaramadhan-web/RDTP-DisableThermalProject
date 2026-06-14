#!/system/bin/sh
# ============================================================
# RizkiDisableThermalProject (RDTP) v2.3
# post-fs-data.sh — Layer 1: Property Override Only
# ============================================================

MODDIR="${0%/*}"
LOG="/data/local/tmp/rdtp_thermal_postfs.log"

# Pastikan /data sudah mount sebelum logging
if [ ! -d "/data/local/tmp" ]; then
    mkdir -p /data/local/tmp 2>/dev/null || true
fi

log_msg() {
    echo "[$(date '+%H:%M:%S')] [post-fs] $1" >> "$LOG" 2>/dev/null || true
}

log_msg "=== RDTP Disable Thermal v2.3 — post-fs-data START ==="

# ── Layer 1: Override Properties via resetprop ──────────
# Ini aman dieksekusi di post-fs-data untuk mencegah config bawaan di-load
#
# FIX v2.3: deteksi resetprop disamakan dengan service.sh agar
# support KernelSU Next (sebelumnya fallback hanya ke path Magisk,
# sehingga di device KSU-only Layer 1 jadi no-op).
find_resetprop() {
    for _rp in \
        "/data/adb/ksu/bin/resetprop" \
        "/data/adb/magisk/resetprop" \
        "$(command -v resetprop 2>/dev/null)"; do
        [ -x "$_rp" ] && echo "$_rp" && return 0
    done
    command -v resetprop >/dev/null 2>&1 && echo "resetprop" && return 0
    return 1
}

RESETPROP_BIN=$(find_resetprop)
if [ -n "$RESETPROP_BIN" ]; then
    # Hapus config bawaan vendor
    "$RESETPROP_BIN" -n vendor.thermal.config "" 2>/dev/null
    "$RESETPROP_BIN" -n persist.vendor.thermal.config "" 2>/dev/null
    "$RESETPROP_BIN" -n persist.vendor.thermal.override.config "" 2>/dev/null
    log_msg "resetprop ($RESETPROP_BIN): thermal config properties cleared"
else
    log_msg "WARNING: resetprop not found (Magisk/KSU), skipping prop override"
fi

# ============================================================
# CATATAN PENTING: 
# Semua manipulasi sysfs (/sys/class/thermal/...) dan mematikan 
# service (init.svc.mi_thermald) TELAH DIPINDAH ke service.sh!
# Jangan pernah mengeksekusinya di fase post-fs-data.
# ============================================================

log_msg "=== post-fs-data DONE ==="