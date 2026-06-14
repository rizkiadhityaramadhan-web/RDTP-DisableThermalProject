#!/system/bin/sh
# ============================================================
# RizkiDisableThermalProject (RDTP) v2.3
# uninstall.sh — Clean Uninstall
# ============================================================

LOG="/data/local/tmp/rdtp_thermal.log"
LOG_POST="/data/local/tmp/rdtp_thermal_postfs.log"

log_msg() {
    echo "[$(date '+%H:%M:%S')] [uninstall] $1" >> "$LOG" 2>/dev/null || true
}

log_msg "=== RDTP Thermal Uninstall dimulai ==="
log_msg "Mengembalikan state sistem sementara sebelum reboot..."

# Re-enable semua thermal zones
COUNT=0
for ZONE in /sys/class/thermal/thermal_zone*/mode; do
    if [ -f "$ZONE" ]; then
        echo "enabled" > "$ZONE" 2>/dev/null && COUNT=$((COUNT + 1))
    fi
done
log_msg "Re-enabled $COUNT thermal zones"

# Re-enable msm_thermal (legacy)
for PARAM in \
    "/sys/module/msm_thermal/parameters/enabled:Y" \
    "/sys/module/msm_thermal/core_control/enabled:1" \
    "/sys/kernel/msm_thermal/enabled:1"; do
    PATH_=${PARAM%%:*}
    VAL_=${PARAM##*:}
    [ -f "$PATH_" ] && echo "$VAL_" > "$PATH_" 2>/dev/null && log_msg "Restored $PATH_"
done

# Start kembali thermal services
for SVC in vendor.thermal-engine mi_thermald thermal-engine thermalservice thermal thermald; do
    start "$SVC" 2>/dev/null && log_msg "Started: $SVC"
done

log_msg "=== Uninstall selesai. Membersihkan sisa file log... ==="

# Hapus log modul ini di URUTAN PALING AKHIR supaya tidak ter-create lagi
rm -f "$LOG" 2>/dev/null
rm -f "$LOG_POST" 2>/dev/null