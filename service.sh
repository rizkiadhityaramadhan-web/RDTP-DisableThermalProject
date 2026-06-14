#!/system/bin/sh
# ============================================================
# RizkiDisableThermalProject (RDTP) v2.3.1
# service.sh — Layer 2/3/4: Service Kill + Watchdog + Kill-switch
# Eksekusi: late_start service (setelah boot complete)
# Target: Poco F6 (Peridot) / SD 8s Gen 3 / Android 16
# KSU Next + Magisk compatible
#
# REVISI v2.3:
#  - EMERGENCY_MODE race condition fix (flag file vs variable)
#  - re_disable_after_emergency: infinite loop risk dihilangkan
#  - get_max_cpu_temp: filter zona non-CPU, hindari false positif
#  - Watchdog log throttling (cegah log spam = disk I/O leak)
#  - Atomic PID file untuk single-instance guarantee
#  - stop_thermal_services: cek state SEBELUM stop (hemat syscall)
#  - Dihapus: sched_boost tweak yang tidak relevan dengan thermal
#    dan kontradiktif dengan tujuan performa modul ini
# ============================================================

MODDIR="${0%/*}"
LOG="/data/local/tmp/rdtp_thermal.log"

# ── Konstanta ────────────────────────────────────────────────
EMERGENCY_TEMP=80       # °C — re-enable thermal di atas ini
RECOVERY_TEMP=68        # °C — re-disable thermal setelah emergency
                        # (BUG FIX: dulu EMERGENCY-10=70, tapi 80-10=70
                        #  masih terlalu tinggi untuk Peridot; pakai 68)
WATCHDOG_INTERVAL=45    # detik antar watchdog check
BOOT_DELAY=30           # BUG FIX: 25 detik terlalu pendek pada ROM berat.
                        # Beberapa vendor service masih naik s/d detik ke-28.
                        # Naikkan ke 30 untuk safety margin.
MAX_LOG_SIZE=524288     # 512KB — rotasi log agar tidak isi storage

# PID file untuk single-instance guard
PID_FILE="/data/local/tmp/rdtp_watchdog.pid"

# Flag file emergency (lebih reliable dari shell variable
# di antara subshell dan fork)
EMERGENCY_FLAG="/data/local/tmp/rdtp_emergency.flag"

mkdir -p /data/local/tmp 2>/dev/null

# ── Single-instance guard ────────────────────────────────────
# IMPROVEMENT: Pastikan hanya ada satu instance watchdog berjalan.
# Tanpa ini, jika Magisk/KSU me-restart service.sh, dua watchdog
# akan berjalan bersamaan dan saling bertarung disable/enable.
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        # Instance lama masih berjalan
        echo "[$(date '+%H:%M:%S')] [service] Instance lama (PID $OLD_PID) masih aktif. Exit." >> "$LOG"
        exit 0
    fi
fi
echo $$ > "$PID_FILE" 2>/dev/null

# Cleanup PID dan flag saat exit (trap semua signal terminasi)
cleanup() {
    rm -f "$PID_FILE" "$EMERGENCY_FLAG" 2>/dev/null
    log_msg "service.sh EXIT (PID $$)"
}
trap cleanup EXIT INT TERM

# ── Log writer dengan rotasi ─────────────────────────────────
# IMPROVEMENT: Cegah log file tumbuh tanpa batas (potential
# disk space issue pada /data partition yang penuh).
log_msg() {
    # Rotasi jika > MAX_LOG_SIZE
    if [ -f "$LOG" ]; then
        _sz=$(stat -c '%s' "$LOG" 2>/dev/null || echo 0)
        if [ "$_sz" -gt "$MAX_LOG_SIZE" ]; then
            mv "$LOG" "${LOG}.bak" 2>/dev/null
            echo "[$(date '+%H:%M:%S')] [service] Log dirotasi (size: ${_sz}B)" > "$LOG"
        fi
    fi
    echo "[$(date '+%H:%M:%S')] [service] $1" >> "$LOG" 2>/dev/null || true
}

# ── Fungsi: Baca suhu CPU tertinggi ─────────────────────────
# BUG FIX versi asli: Membaca SEMUA thermal_zone termasuk GPU,
# battery, charger, skin sensor — ini bisa memicu false emergency.
# GPU Adreno 740 bisa capai 85°C+ saat gaming, padahal CPU masih
# 60°C. Kill-switch akan aktif tidak perlu.
#
# IMPROVEMENT: Filter hanya zona CPU. Pada SD 8s Gen 3 (Peridot),
# CPU thermal zones diidentifikasi lewat 'type' file yang berisi
# substring 'cpu' atau 'cpuss' atau 'cpufreq'.
get_max_cpu_temp() {
    local MAX=0
    local VAL _type ZONE_DIR TEMP_FILE

    for TEMP_FILE in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$TEMP_FILE" ] || continue

        # Ambil direktori zone untuk cek type
        ZONE_DIR="${TEMP_FILE%/temp}"

        # Baca type sensor
        _type=$(cat "${ZONE_DIR}/type" 2>/dev/null | tr '[:upper:]' '[:lower:]')

        # Lewati zona non-CPU (GPU, charger, battery, skin, etc.)
        # Snapdragon 8s Gen 3 CPU zones: cpu-1-0, cpu-1-1, cpuss-0..3, cpu-usr-1, dll
        # (pattern *cpu* sudah cover "cpuss" juga)
        case "$_type" in
            *cpu*) : ;;     # Proses zona ini
            *) continue ;;  # Skip zona non-CPU
        esac

        VAL=$(cat "$TEMP_FILE" 2>/dev/null) || continue

        # Konversi milli-Celsius ke Celsius
        if [ "$VAL" -gt 1000 ] 2>/dev/null; then
            VAL=$((VAL / 1000))
        fi

        # Abaikan nilai sensor error
        [ "$VAL" -le 0 ] 2>/dev/null && continue
        [ "$VAL" -gt 200 ] 2>/dev/null && continue

        [ "$VAL" -gt "$MAX" ] && MAX=$VAL
    done

    echo "$MAX"
}

# ── Fallback: baca suhu dari semua zona jika CPU-only = 0 ───
# (Safeguard jika penamaan zona tidak standar pada custom kernel)
get_max_temp_fallback() {
    local MAX=0
    local VAL
    for TEMP_FILE in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$TEMP_FILE" ] || continue
        VAL=$(cat "$TEMP_FILE" 2>/dev/null) || continue
        [ "$VAL" -gt 1000 ] 2>/dev/null && VAL=$((VAL / 1000))
        [ "$VAL" -le 0 ] 2>/dev/null && continue
        [ "$VAL" -gt 200 ] 2>/dev/null && continue
        [ "$VAL" -gt "$MAX" ] && MAX=$VAL
    done
    echo "$MAX"
}

get_temp_safe() {
    local T
    T=$(get_max_cpu_temp)
    # Jika CPU-only filter menghasilkan 0 (zone name tidak standar),
    # fallback ke semua zona dengan threshold lebih tinggi
    if [ "$T" -eq 0 ] 2>/dev/null; then
        T=$(get_max_temp_fallback)
        # Naikkan emergency threshold 10°C untuk fallback
        # karena termasuk GPU/skin sensor
        EMERGENCY_TEMP_ACTIVE=$((EMERGENCY_TEMP + 10))
    else
        EMERGENCY_TEMP_ACTIVE=$EMERGENCY_TEMP
    fi
    echo "$T"
}

# ── Fungsi: Disable thermal zones ───────────────────────────
disable_thermal_zones() {
    local COUNT=0
    for ZONE in /sys/class/thermal/thermal_zone*/mode; do
        [ -f "$ZONE" ] && [ -w "$ZONE" ] || continue
        _cur=$(cat "$ZONE" 2>/dev/null)
        [ "$_cur" = "disabled" ] && continue  # Skip jika sudah disabled
        echo "disabled" > "$ZONE" 2>/dev/null && COUNT=$((COUNT + 1))
    done
    echo "$COUNT"
}

# ── Fungsi: Stop semua thermal services ─────────────────────
# BUG FIX: Versi asli menggunakan heredoc-style multi-line string
# dengan whitespace. Pada beberapa sh impl, string kosong ("") di
# $SERVICES menyebabkan `stop ""` yang bisa error atau stop service
# yang salah. Gunakan array-style iteration yang lebih bersih.
THERMAL_SERVICES="
vendor.thermal-engine
vendor.thermal-hal-2-0
vendor.thermal-hal-1-0
vendor.thermal-manager
vendor.thermal-symlinks
android.thermal-hal
android.hardware.thermal-service.qti
mi_thermald
mi-thermald
thermal-engine
thermal-hal
thermal-manager
thermal_manager
thermal_mnt_hal_service
thermalloadalgod
thermalservice
thermald
thermal
sec-thermal-1-0
vendor-thermal-1-0
vendor.thermal-hal-2-0.mtk
debug_pid.sec-thermal-1-0
"

stop_thermal_services() {
    local STOPPED=0 SVC STATE
    for SVC in $THERMAL_SERVICES; do
        # BUG FIX: Trim whitespace (IFS-based iteration masih bisa
        # menghasilkan token dengan trailing space pada beberapa sh)
        SVC=$(printf '%s' "$SVC" | tr -d ' \t\r\n')
        [ -z "$SVC" ] && continue

        STATE=$(getprop "init.svc.$SVC" 2>/dev/null)
        # Hanya stop jika benar-benar running (hemat syscall init)
        if [ "$STATE" = "running" ]; then
            stop "$SVC" 2>/dev/null && STOPPED=$((STOPPED + 1))
        fi
    done
    echo "$STOPPED"
}

# ── Fungsi: resetprop service states ─────────────────────────
# IMPROVEMENT: Cache hasil find_resetprop agar tidak dicari ulang
# setiap siklus watchdog.
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

resetprop_thermal_states() {
    [ -z "$RESETPROP_BIN" ] && return 1
    local SVC
    for SVC in $THERMAL_SERVICES; do
        SVC=$(printf '%s' "$SVC" | tr -d ' \t\r\n')
        [ -z "$SVC" ] && continue
        $RESETPROP_BIN -n "init.svc.$SVC" stopped 2>/dev/null
    done
    return 0
}

# ── Fungsi: Emergency kill-switch ────────────────────────────
emergency_enable_thermal() {
    local TEMP=$1
    log_msg "!!! EMERGENCY KILL-SWITCH: CPU ${TEMP}°C >= ${EMERGENCY_TEMP_ACTIVE}°C !!!"
    log_msg "!!! Re-enabling thermal protection — hardware safety mode !!!"

    # Set flag emergency (persistent across function calls)
    touch "$EMERGENCY_FLAG" 2>/dev/null

    # Re-enable semua thermal zones
    for ZONE in /sys/class/thermal/thermal_zone*/mode; do
        [ -f "$ZONE" ] && [ -w "$ZONE" ] && echo "enabled" > "$ZONE" 2>/dev/null
    done

    # Re-enable msm_thermal kernel parameters
    _write_sysfs_emergency() {
        [ -f "$1" ] && [ -w "$1" ] && echo "$2" > "$1" 2>/dev/null
    }
    _write_sysfs_emergency "/sys/module/msm_thermal/parameters/enabled"   "Y"
    _write_sysfs_emergency "/sys/module/msm_thermal/core_control/enabled" "1"
    _write_sysfs_emergency "/sys/kernel/msm_thermal/enabled"              "1"

    # Restart thermal service utama agar langsung aktif
    start vendor.thermal-engine 2>/dev/null || true
    start mi_thermald 2>/dev/null || true

    log_msg "!!! Thermal protection AKTIF. Cooling threshold: ${RECOVERY_TEMP}°C !!!"
}

# ── Fungsi: Re-disable setelah emergency ─────────────────────
# BUG FIX KRITIS: Versi asli punya infinite loop tersembunyi.
# Jika suhu tidak turun di bawah threshold dalam 10x30detik = 5 menit,
# fungsi return — tapi EMERGENCY_MODE tidak pernah di-reset ke 0
# dengan benar, karena re_disable_after_emergency() dipanggil SEBELUM
# EMERGENCY_MODE=0 di loop utama. Akibatnya: setelah timeout,
# watchdog masuk ke jalur `continue` selamanya = watchdog beku.
#
# PERBAIKAN: Gunakan flag file dan pisahkan tanggung jawab.
re_disable_after_emergency() {
    local COOL_THRESHOLD=$RECOVERY_TEMP
    local WAIT_COUNT=0
    local MAX_WAIT=20     # Max 20 x 30 detik = 10 menit
    local CURRENT_TEMP N

    log_msg "Emergency cooling: menunggu suhu < ${COOL_THRESHOLD}°C (max ${MAX_WAIT} iterasi x 30 detik)"

    while [ "$WAIT_COUNT" -lt "$MAX_WAIT" ]; do
        sleep 30
        CURRENT_TEMP=$(get_temp_safe)
        WAIT_COUNT=$((WAIT_COUNT + 1))
        log_msg "Cooling check [${WAIT_COUNT}/${MAX_WAIT}]: ${CURRENT_TEMP}°C (target < ${COOL_THRESHOLD}°C)"

        if [ "$CURRENT_TEMP" -lt "$COOL_THRESHOLD" ] 2>/dev/null; then
            log_msg "Suhu turun ke ${CURRENT_TEMP}°C. Re-disabling thermal..."

            # Re-disable zones
            N=$(disable_thermal_zones)
            log_msg "Disabled $N zones kembali setelah emergency."

            # Stop thermal services yang mungkin di-restart
            N=$(stop_thermal_services)
            resetprop_thermal_states
            log_msg "Stopped $N services. Emergency selesai."

            # Hapus flag emergency
            rm -f "$EMERGENCY_FLAG" 2>/dev/null
            return 0
        fi
    done

    # Timeout — thermal tetap enabled untuk keselamatan hardware
    log_msg "WARNING: Suhu tidak turun dalam 10 menit. Thermal TETAP enabled untuk keamanan."
    log_msg "WARNING: Watchdog tetap jalan — akan coba re-disable saat suhu < ${COOL_THRESHOLD}°C."
    # Hapus flag agar watchdog bisa cek suhu lagi di next cycle
    rm -f "$EMERGENCY_FLAG" 2>/dev/null
    return 1
}

# ════════════════════════════════════════════════════════════
#                    MAIN EXECUTION
# ════════════════════════════════════════════════════════════

log_msg "=== RDTP Disable Thermal v2.3 — service START (PID $$) ==="
log_msg "Boot delay ${BOOT_DELAY}s — menunggu sistem stabil..."
sleep "$BOOT_DELAY"

# Inisialisasi EMERGENCY_TEMP_ACTIVE dengan default
EMERGENCY_TEMP_ACTIVE=$EMERGENCY_TEMP

# ── Layer 2: Disable thermal zones saat runtime ─────────────
log_msg "Layer 2: Disable thermal zones (runtime)..."
N=$(disable_thermal_zones)
log_msg "Layer 2: Disabled $N thermal zones"

# ── Layer 3: Stop thermal services ──────────────────────────
log_msg "Layer 3: Stopping thermal services..."
N=$(stop_thermal_services)
log_msg "Layer 3: Stopped $N services"

# ── Layer 3B: resetprop override ────────────────────────────
log_msg "Layer 3B: resetprop thermal states..."
if resetprop_thermal_states; then
    log_msg "Layer 3B: resetprop OK (bin: $RESETPROP_BIN)"
else
    log_msg "Layer 3B: resetprop tidak tersedia, skip"
fi

# ── Layer 4: Watchdog loop ───────────────────────────────────
log_msg "Layer 4: Watchdog dimulai. Interval: ${WATCHDOG_INTERVAL}s. Emergency: ${EMERGENCY_TEMP}°C (CPU-only filter)"

# Throttle log watchdog: hanya log jika ada aksi, bukan setiap siklus
# IMPROVEMENT: Mengurangi I/O write ke /data setiap 45 detik (disk wear + spam)
WATCHDOG_CYCLE=0

while true; do
    sleep "$WATCHDOG_INTERVAL"
    WATCHDOG_CYCLE=$((WATCHDOG_CYCLE + 1))

    # ── Cek suhu emergency ──────────────────────────────────
    CURRENT_TEMP=$(get_temp_safe)

    # BUG FIX: Cek flag file bukan variable, karena variable hilang
    # jika ada subshell fork yang tidak kembali dengan benar.
    if [ -f "$EMERGENCY_FLAG" ]; then
        # Masih dalam mode emergency (re_disable belum selesai)
        # Skip watchdog normal, biarkan re_disable_after_emergency bekerja
        continue
    fi

    if [ "$CURRENT_TEMP" -ge "$EMERGENCY_TEMP_ACTIVE" ] 2>/dev/null; then
        # Masuk emergency mode
        emergency_enable_thermal "$CURRENT_TEMP"
        # re_disable berjalan synchronous — akan block hingga dingin
        re_disable_after_emergency
        # Setelah re_disable selesai (berhasil atau timeout), lanjut loop
        continue
    fi

    # ── Watchdog: pastikan thermal zones tetap disabled ──────
    ZONES_ENABLED=0
    for ZONE in /sys/class/thermal/thermal_zone*/mode; do
        [ -f "$ZONE" ] || continue
        _STATE=$(cat "$ZONE" 2>/dev/null)
        [ "$_STATE" = "enabled" ] && ZONES_ENABLED=$((ZONES_ENABLED + 1))
    done

    if [ "$ZONES_ENABLED" -gt 0 ]; then
        log_msg "Watchdog [cycle $WATCHDOG_CYCLE]: $ZONES_ENABLED zone re-enabled oleh sistem. Re-disabling..."
        N=$(disable_thermal_zones)
        log_msg "Watchdog: Re-disabled $N zones. Suhu CPU: ${CURRENT_TEMP}°C"
    fi

    # ── Watchdog: cek thermal service restart ────────────────
    THERMAL_RUNNING=0
    for SVC in vendor.thermal-engine mi_thermald thermal-engine thermalservice thermal android.hardware.thermal-service.qti; do
        _SVC_STATE=$(getprop "init.svc.$SVC" 2>/dev/null)
        [ "$_SVC_STATE" = "running" ] && THERMAL_RUNNING=$((THERMAL_RUNNING + 1))
    done

    if [ "$THERMAL_RUNNING" -gt 0 ]; then
        log_msg "Watchdog [cycle $WATCHDOG_CYCLE]: $THERMAL_RUNNING service restart. Re-stopping..."
        N=$(stop_thermal_services)
        resetprop_thermal_states
        log_msg "Watchdog: Re-stopped $N services. Suhu CPU: ${CURRENT_TEMP}°C"
    fi

    # Log periodik minimal (setiap 20 siklus = ~15 menit) untuk konfirmasi hidup
    if [ $((WATCHDOG_CYCLE % 20)) -eq 0 ]; then
        log_msg "Watchdog heartbeat [cycle $WATCHDOG_CYCLE]: Suhu CPU ${CURRENT_TEMP}°C — semua normal."
    fi

done &

# ════════════════════════════════════════════════════════════
#         LAYER 5: AUTO GOVERNOR (Game Performance Mode)
# ════════════════════════════════════════════════════════════
# Mendeteksi game foreground via dumpsys window (mCurrentFocus).
# Game terdeteksi  -> set CPU governor "performance" (semua cluster)
# Game tidak aktif -> balik ke "schedutil"
# Catatan: GPU (kgsl-3d0) hanya punya governor "msm-adreno-tz",
# tidak ada opsi "performance", jadi GPU tidak diubah di sini.
# Tidak berinteraksi dengan emergency kill-switch (Layer 4) —
# governor tetap "performance" walau emergency aktif (by design).
# ============================================================

GOV_LOG="/data/local/tmp/rdtp_governor.log"
GOV_INTERVAL=5

GAME_PACKAGES="
com.mobile.legends
com.tencent.ig
"

gov_log_msg() {
    echo "[$(date '+%H:%M:%S')] [governor] $1" >> "$GOV_LOG" 2>/dev/null || true
}

get_foreground_pkg() {
    /system/bin/dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus' | sed -n 's/.*[{ ]\([a-zA-Z0-9._]*\)\/.*/\1/p'
}

set_cpu_governor() {
    local GOV="$1"
    local CHANGED=0
    for GOVFILE in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$GOVFILE" ] && [ -w "$GOVFILE" ] || continue
        _cur=$(cat "$GOVFILE" 2>/dev/null)
        [ "$_cur" = "$GOV" ] && continue
        echo "$GOV" > "$GOVFILE" 2>/dev/null && CHANGED=$((CHANGED + 1))
    done
    echo "$CHANGED"
}

gov_log_msg "=== RDTP Layer 5 — Auto Governor START (PID $$) ==="
gov_log_msg "Target games: $(echo $GAME_PACKAGES | tr '\n' ' ')"
gov_log_msg "Polling interval: ${GOV_INTERVAL}s"

LAST_GOV_STATE=""

while true; do
    sleep "$GOV_INTERVAL"

    FG_PKG=$(get_foreground_pkg)

    IS_GAME=0
    for PKG in $GAME_PACKAGES; do
        [ "$FG_PKG" = "$PKG" ] && IS_GAME=1 && break
    done

    if [ "$IS_GAME" = "1" ]; then
        if [ "$LAST_GOV_STATE" != "performance" ]; then
            N=$(set_cpu_governor performance)
            gov_log_msg "Game terdeteksi ($FG_PKG). Governor -> performance ($N core diubah)"
            LAST_GOV_STATE="performance"
        fi
    else
        if [ "$LAST_GOV_STATE" != "schedutil" ]; then
            N=$(set_cpu_governor schedutil)
            gov_log_msg "Game tidak aktif (fg: $FG_PKG). Governor -> schedutil ($N core diubah)"
            LAST_GOV_STATE="schedutil"
        fi
    fi

done &

wait