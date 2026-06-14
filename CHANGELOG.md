# RizkiDisableThermalProject (RDTP) — Changelog

## Version 2.4 (2026)
- **NEW (Layer 5 — Auto Governor / Game Performance Mode)**:
  Background loop di `service.sh` mendeteksi app foreground via
  `dumpsys window` (`mCurrentFocus`), polling setiap 5 detik.
  - Game terdaftar aktif (`com.mobile.legends`, `com.tencent.ig`) ->
    set CPU governor `performance` di semua cluster (writable,
    tersedia di SD 8s Gen 3: little/mid/big)
  - Game tidak aktif -> balik ke `schedutil`
  - GPU (kgsl-3d0) TIDAK diubah — hanya ada governor
    `msm-adreno-tz`, tidak ada opsi `performance`
  - Loop ini berjalan independen/paralel dengan watchdog thermal
    (Layer 4), tidak saling block (`&` + `wait` di akhir service.sh)
  - **CATATAN PENTING**: Layer 5 TIDAK berinteraksi dengan emergency
    kill-switch (Layer 4). Jika suhu CPU >= 80°C saat governor =
    `performance`, thermal HAL akan di-re-enable (Layer 4) namun
    governor TETAP `performance` — kedua mekanisme bisa saling
    "tarik" clock speed CPU, dan proses cooling ke ambang
    RECOVERY_TEMP (68°C) bisa berjalan lebih lambat atau tidak
    tercapai dalam window timeout 10 menit. Ini adalah keputusan
    desain yang disengaja (governor tidak diturunkan otomatis saat
    emergency) — gunakan dengan kesadaran risiko ini.
  - Log terpisah: `/data/local/tmp/rdtp_governor.log`

## Version 2.3.1 (2026)
- **FIX (RC Override)**: Target service di RC override sebelumnya hanya cover
  `android.hardware.thermal@1.0-service` (HIDL legacy). Peridot/Evo X pada
  Android 16 menjalankan `android.hardware.thermal-service.qti` (AIDL modern,
  QTI thermal HAL Android 13+) — service ini tidak ter-disable oleh RC lama.
  Tambah entry baru di `android.hardware.thermal@1.0-service.rc`
- **FIX (Watchdog)**: `android.hardware.thermal-service.qti` ditambahkan ke
  `THERMAL_SERVICES` dan loop watchdog di `service.sh` agar ter-cover oleh
  `stop_thermal_services()` dan watchdog restart detection
- **COSMETIC**: Header komentar kedua file RC diupdate dari v2.2 → v2.3.1

## Version 2.3 (2026)
- **Lightweight rebuild** — package size turun ~53% (220KB → ~104KB unpacked)
- **REMOVED**: 28 file `system/vendor/etc/thermal-*.conf` & `thermald-devices.conf`
  - File-file ini ternyata isinya **random binary garbage** (entropy ~7.9 bit/byte),
    bukan config Qualcomm/Xiaomi yang valid — bukan placeholder kosong yang aman
  - Tidak pernah dibaca oleh post-fs-data.sh / service.sh (dead weight)
  - Karena nama file match dengan config asli vendor (`thermal-cgame.conf`,
    `thermal-yuanshen.conf`, `thermal-map.conf`, dll), Magisk magic-mount akan
    MENIMPA config asli device dengan byte sampah ini
  - **Risiko kritis**: kalau emergency kill-switch (Layer 4, suhu ≥80°C) memanggil
    `start vendor.thermal-engine` / `start mi_thermald`, daemon tersebut bisa
    crash saat parsing config corrupt — justru di momen paling butuh thermal
    protection. Menghapus file-file ini membuat config ASLI device tetap utuh
    dan siap dipakai thermal-engine kalau emergency restart benar-benar terjadi
  - RC override (`init/*.rc`) tetap dipertahankan — file kecil, teks valid,
    best-effort layer tambahan di level init
- **FIX (KSU Next)**: `post-fs-data.sh` sebelumnya hanya fallback ke
  `/data/adb/magisk/resetprop` kalau `which resetprop` gagal di stage post-fs-data
  (PATH belum lengkap) → Layer 1 jadi no-op di device KSU-only. Sekarang pakai
  `find_resetprop()` yang sama dengan `service.sh` (cek `/data/adb/ksu/bin/resetprop`
  dulu, baru Magisk, baru PATH)
- **FIX**: Layer 1 sekarang juga clear `persist.vendor.thermal.override.config`
  (konsisten dengan `system.prop`)
- **CLEANUP**: hapus tweak `sched_boost=0` di `service.sh` — tidak relevan dengan
  thermal dan kontradiktif dengan tujuan performa modul
- **CLEANUP**: hapus `ro.config.low_battery_warning_level=3` di `system.prop` —
  tidak ada hubungan dengan thermal, kemungkinan leftover dari prop list lain
- **CLEANUP**: simplifikasi pattern matching CPU zone di `get_max_cpu_temp()`
  (`*cpu*` sudah cover `*cpuss*`)
- Versioning disamakan di semua file (sebelumnya `module.prop`=v2.2 vs
  `service.sh`=v2.3-REVISED)

## Version 2.2 (2025)
- **Full rebuild** untuk KSU Next + Magisk modern compatibility
- Ganti `update-binary` lama (2018 template) → `customize.sh` modern
- **New Safe Execution Architecture (Anti-Bootloop):**
  - Layer 1: Property Override via `post-fs-data` (Hanya menghapus config bawaan vendor)
  - Layer 2: Runtime sysfs disable dipindah ke `service.sh` (Eksekusi aman saat late_start)
  - Layer 3: **Auto-Injeksi Dummy File** — Binary thermal vendor (mi_thermald, dll) di-set permission `0000` saat instalasi agar lumpuh permanen
  - Layer 4: Watchdog loop dengan auto re-disable jika sistem restart thermal
- **Emergency hardware kill-switch** pada 80°C+ (re-enable thermal otomatis, re-disable saat suhu turun)
- **RC file override** untuk disable thermal HAL di level init
- `resetprop` integration diganti dan dimaksimalkan untuk Android 16 compatibility
- Log file dipisah untuk tracking lebih presisi (`/data/local/tmp/`)
- Target: Poco F6 (Peridot), ROM Lunaris 3.11 / Evolution X, Android 16

## Version 1.1 (2024-11-30)
- Minor update
- Stabilization system

## Version 1.0 (2024)
- Universal Initial Build Version 1.0