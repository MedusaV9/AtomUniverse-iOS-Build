#!/usr/bin/env bash
# Runs a DetProbe app (Unity iOS Simulator build) in the iOS Simulator and reads its result line.
#
# Usage: detprobe-simulator.sh --app <x.app> --out <dir> [--timeout <seconds>] [--arg <launch-argument>]
#
# Signs the simulator app ad hoc (never for devices), boots the first available iPhone simulator (or
# creates one), installs and launches the app with -atomuniverse-detprobe and waits until it quits.
# The probe writes "ATOMUNIVERSE_DETPROBE v=1 ..." to Documents/atomuniverse-detprobe.txt in its data
# container and to stdout; the console is the fallback. Results:
#   <out>/probe.txt               the probe line (plus ATOMUNIVERSE_DETPROBE_CASE lines on a mismatch)
#   <out>/simulator-console.log   last 500 console lines of the app
#   <out>/evidence.txt            PROBE_* and SIM_* KEY=VALUE lines appended (also to $GITHUB_OUTPUT)
# Exit 1 if no probe line was found. Runs with the bash 3.2 that ships with macOS.
set -euo pipefail

die() { echo "detprobe-simulator: $*" >&2; exit 1; }

app="" out="" timeout=300 launch_arg=-atomuniverse-detprobe
while [ $# -gt 0 ]; do
  case $1 in
    --app) app=${2:?--app needs a value}; shift 2 ;;
    --out) out=${2:?--out needs a value}; shift 2 ;;
    --timeout) timeout=${2:?--timeout needs a value}; shift 2 ;;
    --arg) launch_arg=${2:?--arg needs a value}; shift 2 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$app" ] || die "--app must be an .app directory (got: '$app')"
[ -n "$out" ] || die "--out is required"
printf '%s' "$timeout" | grep -Eq '^[0-9]{1,4}$' || die "--timeout must be seconds"
mkdir -p "$out"
out=$(cd "$out" && pwd)
evidence="$out/evidence.txt"
console="$out/simulator-console.log"
probe="$out/probe.txt"
rm -f "$console" "$probe"

# Perl instead of GNU timeout (not on macOS): SIGALRM ends the exec'd command.
with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
echo "App $(basename "$app"), bundle id $bundle"
# The iOS Simulator on Apple silicon only runs signed arm64 code; ad hoc is enough there.
codesign --force --deep --sign - "$app" >/dev/null

pick=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
for runtime in sorted(devs, reverse=True):
    if ".iOS-" not in runtime:
        continue
    for d in devs[runtime]:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            print(d["udid"], runtime, d["name"].replace(" ", "_"))
            sys.exit(0)
')
if [ -z "$pick" ]; then
  runtime=$(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
print(rts[-1]["identifier"] if rts else "")')
  [ -n "$runtime" ] || die "no available iOS simulator runtime"
  devtype=$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
t = [d["identifier"] for d in json.load(sys.stdin)["devicetypes"] if d["name"].startswith("iPhone")]
print(t[-1] if t else "")')
  [ -n "$devtype" ] || die "no iPhone device type"
  udid=$(xcrun simctl create detprobe-iphone "$devtype" "$runtime")
  pick="$udid $runtime created-$(basename "$devtype")"
fi
# shellcheck disable=SC2086  # split "udid runtime name" into three words
set -- $pick
udid=$1 sim_runtime=$2 sim_device=$3
echo "Simulator $sim_device ($sim_runtime) $udid"

xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
container=$(xcrun simctl get_app_container "$udid" "$bundle" data)
rm -f "$container/Documents/atomuniverse-detprobe.txt"

echo "Launching with $launch_arg (timeout ${timeout}s)"
start=$(date +%s)
set +e
with_timeout "$timeout" xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle" "$launch_arg" \
  >"$out/console-full.log" 2>&1
launch_rc=$?
set -e
seconds=$(($(date +%s) - start))
echo "simctl launch returned $launch_rc after ${seconds}s"

# The file may lag behind the console by a moment.
result_file="$container/Documents/atomuniverse-detprobe.txt"
i=0
while [ ! -s "$result_file" ] && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
src_kind=none
if [ -s "$result_file" ]; then
  tr -d '\r' <"$result_file" | grep -a 'ATOMUNIVERSE_DETPROBE' >"$probe" || true
  [ -s "$probe" ] && src_kind="file"
fi
if [ "$src_kind" = none ]; then
  tr -d '\r' <"$out/console-full.log" | grep -a -o 'ATOMUNIVERSE_DETPROBE.*' >"$probe" || true
  [ -s "$probe" ] && src_kind="console"
fi
tail -n 500 "$out/console-full.log" >"$console"
rm -f "$out/console-full.log"
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true

line=$(grep -a -o -m1 'ATOMUNIVERSE_DETPROBE v=1 .*' "$probe" 2>/dev/null || true)
field() { printf ' %s' "$line" | sed -n "s/.* $1=\([^ ]*\).*/\1/p"; }
{
  echo "PROBE_LINE=$line"
  echo "PROBE_MATCH=$(field match)"
  echo "PROBE_CHECKSUM=$(field checksum)"
  echo "PROBE_EXPECTED=$(field expected)"
  echo "PROBE_TRIGGER=$(field trigger)"
  echo "PROBE_BACKEND=$(field backend)"
  echo "PROBE_PLATFORM=$(field platform)"
  echo "PROBE_ARCH=$(field arch)"
  echo "PROBE_SOURCE=$src_kind"
  echo "SIM_DEVICE=$sim_device"
  echo "SIM_RUNTIME=$sim_runtime"
  echo "LAUNCH_RC=$launch_rc"
  echo "LAUNCH_SECONDS=$seconds"
} >"$out/probe-evidence.txt"
cat "$out/probe-evidence.txt"
cat "$out/probe-evidence.txt" >>"$evidence"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  while IFS='=' read -r key value; do
    printf '%s=%s\n' "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" "$value"
  done <"$out/probe-evidence.txt" >>"$GITHUB_OUTPUT"
fi
rm -f "$out/probe-evidence.txt"

[ -n "$line" ] || die "no ATOMUNIVERSE_DETPROBE line (launch exit $launch_rc, see $console)"
case $(field match) in
  yes) echo "DetProbe match=yes checksum=$(field checksum)" ;;
  *) echo "::warning::DetProbe match=$(field match) checksum=$(field checksum) expected=$(field expected)" ;;
esac
