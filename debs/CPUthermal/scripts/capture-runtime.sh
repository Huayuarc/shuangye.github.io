#!/bin/sh
# Read-only incident snapshot. Run on the phone via sh capture-runtime.sh [output-file].
set -u
out=${1:-"./cputhermal-capture-$(date '+%Y%m%d-%H%M%S').txt"}
case "$out" in -*) echo 'invalid output path' >&2; exit 2;; esac
{
 echo 'CPUthermal incident snapshot (read-only inputs)'
 date '+wall=%Y-%m-%dT%H:%M:%S%z epoch=%s'
 uptime 2>/dev/null || :
 echo '=== process PIDs (CallAssist / thermalmonitord) ==='
 ps -e -o pid,ppid,comm 2>/dev/null | grep -E '(^ *PID|[Cc]all[Aa]ssist|thermalmonitord)' || :
 echo '=== sysctl values (NOT proof of instantaneous core frequency) ==='
 for k in hw.cpufrequency hw.cpufrequency_max; do
  if command -v sysctl >/dev/null 2>&1; then sysctl "$k" 2>&1 || :; else echo "$k: sysctl unavailable"; fi
 done
 echo '=== IORegistry CPU/thermal read-only (bounded by service names) ==='
 if command -v ioreg >/dev/null 2>&1; then
  for n in AppleARMIODevice ApplePMGR AppleSmartBattery; do
   ioreg -r -n "$n" -l 2>&1 | grep -Ei '(^\+-o|frequency|freq|thermal|temperature|cpu|pmgr|brightness)' | head -100 || :
  done
 else echo 'ioreg unavailable'; fi
 echo '=== selected brightness / power notifications (read-only when available) ==='
 if command -v notifyutil >/dev/null 2>&1; then
  notifyutil -g com.apple.springboard.hasBlankedScreen 2>&1 || :
  notifyutil -g com.apple.springboard.lockstate 2>&1 || :
 fi
 echo '=== CPUthermal preferences (only selected nonsecret settings) ==='
 for p in /var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist /var/jb/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist; do
  if [ -r "$p" ] && command -v plutil >/dev/null 2>&1; then
   echo "prefs_path=$p"
   for k in powerMode thermalDimmingPreventionEnabled; do
    plutil -extract "$k" raw "$p" 2>/dev/null | awk -v k="$k" '{print k "=" $0}' || :
   done
  fi
 done
 echo '=== end ==='
} > "$out"
printf 'Captured %s\n' "$out"
