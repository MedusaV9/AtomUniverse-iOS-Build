#!/usr/bin/env bash
# Builds a Unity iOS export without code signing and collects determinism evidence for the sim core.
#
# Usage: detprobe-xcodebuild.sh (--project <x.xcodeproj> | --workspace <x.xcworkspace>) --sdk simulator|device
#                               --out <dir> [--export-dir <dir>]
#
# Runs `xcodebuild build` (scheme Unity-iPhone, Release, arm64) for the iOS Simulator or for generic iOS
# devices. The full log stays in <out>/xcodebuild.log on the runner (it quotes IL2CPP's C++ on errors).
# Evidence, all counts and compiler command lines, never C++ or disassembly:
#   <out>/evidence.txt              KEY=VALUE lines (also appended in lower case to $GITHUB_OUTPUT)
#   <out>/sim-core-clang-lines.txt  clang command lines that compile the sim core (AtomUniverse.Sim*.cpp/.c)
#   <out>/sim-core-objects.txt      per sim-core object file: source, FMA count, instruction count
# FMA = fmadd, fmsub, fnmadd, fnmsub, fmla, fmls (and their SVE/vector forms) in `objdump -d`.
# Runs with the bash 3.2 that ships with macOS (the analysis itself is python3).
set -euo pipefail

die() { echo "detprobe-xcodebuild: $*" >&2; exit 1; }

kind="" path="" sdk="" out="" export_dir=""
while [ $# -gt 0 ]; do
  case $1 in
    --project) kind=-project; path=${2:?--project needs a value}; shift 2 ;;
    --workspace) kind=-workspace; path=${2:?--workspace needs a value}; shift 2 ;;
    --sdk) sdk=${2:?--sdk needs a value}; shift 2 ;;
    --out) out=${2:?--out needs a value}; shift 2 ;;
    --export-dir) export_dir=${2:?--export-dir needs a value}; shift 2 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$kind" ] || die "--project or --workspace is required"
[ -e "$path" ] || die "not found: $path"
[ -n "$out" ] || die "--out is required"
case $sdk in
  simulator) xsdk=iphonesimulator destination='generic/platform=iOS Simulator' target_triple=arm64-apple-ios15.0-simulator ;;
  device) xsdk=iphoneos destination='generic/platform=iOS' target_triple=arm64-apple-ios15.0 ;;
  *) die "--sdk must be simulator or device (got: '$sdk')" ;;
esac
[ -n "$export_dir" ] || export_dir=$(dirname "$path")
export_dir=$(cd "$export_dir" && pwd)

mkdir -p "$out"
out=$(cd "$out" && pwd)
log="$out/xcodebuild.log"
dd="$out/dd"
evidence="$out/evidence.txt"
rm -rf "$dd" "$evidence" "$out/sim-core-clang-lines.txt" "$out/sim-core-objects.txt"

xcode_version=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')
echo "$xcode_version"
echo "Building $path ($xsdk, Release, arm64, no code signing)"
start=$(date +%s)
if ! xcodebuild build \
  "$kind" "$path" \
  -scheme Unity-iPhone \
  -configuration Release \
  -sdk "$xsdk" \
  -destination "$destination" \
  -derivedDataPath "$dd" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  >"$log" 2>&1; then
  # Only diagnostic lines and the list of failed commands: clang's source excerpts would show
  # IL2CPP's C++ generated from game code in this public log.
  grep -E 'error:|\*\* BUILD FAILED' "$log" | tail -n 60 >&2 || true
  sed -n '/The following build commands failed/,$p' "$log" | head -n 30 >&2 || true
  die "xcodebuild build failed (log stays on the runner: $log)"
fi
seconds=$(($(date +%s) - start))
echo "xcodebuild build done in ${seconds}s"

app=$(find "$dd/Build/Products/Release-$xsdk" -maxdepth 1 -type d -name '*.app' 2>/dev/null | head -n 1)
[ -n "$app" ] || die "no .app below $dd/Build/Products/Release-$xsdk"

# Positive control: does this clang fuse a*b+c by default, and does -ffp-contract=off stop it?
control="$out/control"
rm -rf "$control"
mkdir -p "$control"
printf 'double f(double a, double b, double c) { return a * b + c; }\n' >"$control/fma.c"
xcrun --sdk "$xsdk" clang -O3 -target "$target_triple" -c "$control/fma.c" -o "$control/default.o"
xcrun --sdk "$xsdk" clang -O3 -target "$target_triple" -ffp-contract=off -c "$control/fma.c" -o "$control/off.o"
xcrun --sdk "$xsdk" clang -### -O3 -target "$target_triple" -c "$control/fma.c" -o "$control/x.o" >"$control/driver.txt" 2>&1 || true

python3 - "$log" "$export_dir" "$dd" "$out" "$control" "$app" <<'PY'
import os, re, shlex, subprocess, sys

log, export_dir, dd, out, control, app = sys.argv[1:7]
SIM_SRC = re.compile(r'(?:^|[/"\s])(AtomUniverse\.Sim(?:__\d+)?\.cpp|AtomUniverse\.Sim_CodeGen\.c)"?(?:\s|$)')
FMA = re.compile(r'^fn?m(?:add|sub|ad|sb|la|ls)(?:\.[0-9a-z]+)?$')
INSN = re.compile(r'^\s*[0-9a-f]+:\s+(?:(?:[0-9a-f]{2} ){4}\s*)?([a-z][a-z0-9.]*)')
SIM_SYM = re.compile(r'(DetMath|DetProbe)_')
MAX_LINE = 6000
ev = {}

def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace').stdout

def is_compile(line):
    return re.search(r'clang(\+\+)?"?\s', line) is not None and re.search(r'\s-c(\s|$)', line) is not None

def expand_rsp(line):
    """Inline @file response files (path as given, relative to the export dir, or found by basename)."""
    parts = []
    for tok in re.findall(r'"@[^"]+"|@\S+', line):
        name = tok.strip('"')[1:]
        cands = [name, os.path.join(export_dir, name)]
        for c in cands:
            if os.path.isfile(c):
                parts.append(open(c, errors='replace').read().replace('\n', ' '))
                break
        else:
            base = os.path.basename(name)
            for root in (os.path.join(export_dir, 'Il2CppTempDirArtifacts'), dd):
                hit = None
                for r, _, files in os.walk(root, followlinks=True):
                    if base in files:
                        hit = os.path.join(r, base)
                        break
                if hit:
                    parts.append(open(hit, errors='replace').read().replace('\n', ' '))
                    break
    return line + (' ' + ' '.join(parts) if parts else '')

def describe(cmd, source_kind):
    m = SIM_SRC.search(cmd)
    src = m.group(1) if m else ''
    o = re.search(r'\s-o\s+"([^"]+)"|\s-o\s+(\S+)', cmd)
    obj = os.path.basename(o.group(1) or o.group(2)) if o else ''
    fpc = re.findall(r'-ffp-contract=(\w+)', cmd)
    opt = sorted(set(re.findall(r'\s(-O[0-3sz]?)(?=\s|$)', cmd)))
    tgt = re.findall(r'(?:-target\s+|--target=)"?([\w.-]+)', cmd)
    return {'source': src, 'object': obj, 'flag': '-ffp-contract=off' in cmd, 'last_fp_contract': fpc[-1] if fpc else '',
            'opt': ','.join(opt), 'target': tgt[-1] if tgt else '', 'fast_math': '-ffast-math' in cmd, 'kind': source_kind}

# (a) clang command lines from the xcodebuild log (il2cpp --print-command-line), else Bee's DAG files.
lines, all_compile, all_with_flag = [], 0, 0
with open(log, errors='replace') as f:
    for raw in f:
        line = raw.rstrip('\n')
        if not is_compile(line):
            continue
        if '@' in line:
            line = expand_rsp(line)
        all_compile += 1
        all_with_flag += '-ffp-contract=off' in line
        if SIM_SRC.search(line):
            lines.append((line, describe(line, 'log')))
source_kind = 'log' if lines else ''
if not lines:
    import json
    for r, _, files in os.walk(dd):
        for fn in files:
            if not fn.endswith('.dag.json'):
                continue
            try:
                nodes = json.load(open(os.path.join(r, fn))).get('Nodes', [])
            except Exception:
                continue
            for n in nodes:
                action = n.get('Action', '') or ''
                if is_compile(action) and any(SIM_SRC.search(' ' + i + ' ') for i in n.get('Inputs', [])[:1]):
                    lines.append((action, describe(action, 'dag')))
    source_kind = 'dag' if lines else 'none'

with open(os.path.join(out, 'sim-core-clang-lines.txt'), 'w') as f:
    for line, d in lines:
        f.write('# source=%s object=%s from=%s flag=%s last_fp_contract=%s opt=%s target=%s\n' % (
            d['source'], d['object'], d['kind'], 'yes' if d['flag'] else 'no', d['last_fp_contract'] or '-',
            d['opt'] or '-', d['target'] or '-'))
        f.write((line if len(line) <= MAX_LINE else line[:MAX_LINE] + ' …[truncated]') + '\n')
ev['SIM_CORE_CLANG_SOURCE'] = source_kind
ev['SIM_CORE_CLANG_LINES'] = len(lines)
ev['SIM_CORE_CLANG_WITH_FLAG'] = sum(1 for _, d in lines if d['flag'])
ev['SIM_CORE_LAST_FP_CONTRACT'] = ','.join(sorted(set(d['last_fp_contract'] or 'none' for _, d in lines)))
ev['SIM_CORE_OPT'] = ','.join(sorted(set(d['opt'] or 'none' for _, d in lines)))
ev['SIM_CORE_TARGET'] = ','.join(sorted(set(d['target'] or 'none' for _, d in lines)))
ev['SIM_CORE_FAST_MATH'] = sum(1 for _, d in lines if d['fast_math'])
ev['SIM_CORE_SOURCES'] = ','.join(sorted(set(d['source'] for _, d in lines)))
ev['LOG_CLANG_COMPILE_LINES'] = all_compile
ev['LOG_CLANG_COMPILE_WITH_FLAG'] = all_with_flag

# (b) IL2CPP object files (Bee artifacts below the derived data) and their FMA instructions.
def objdump_counts(path):
    insns = fma = 0
    text = run(['xcrun', 'objdump', '-d', '--no-show-raw-insn', path])
    for l in text.splitlines():
        m = INSN.match(l)
        if m:
            insns += 1
            if FMA.match(m.group(1)):
                fma += 1
    return insns, fma

def kind_of(path):
    with open(path, 'rb') as f:
        head = f.read(4)
    if head in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
        return 'macho'
    if head in (b'BC\xc0\xde', b'\xde\xc0\x17\x0b'):
        return 'bitcode'
    return 'other'

objects = []
for r, _, files in os.walk(dd):
    if '/artifacts/' not in r + '/':
        continue
    for fn in files:
        if fn.endswith('.o'):
            objects.append(os.path.join(r, fn))
by_name = {}
for p in objects:
    by_name.setdefault(os.path.basename(p), p)
compiled_from = {d['object']: d['source'] for _, d in lines if d['object']}

all_fma = all_insns = 0
sim_rows = []
kinds = set()
for p in sorted(objects):
    k = kind_of(p)
    kinds.add(k)
    insns, fma = objdump_counts(p) if k == 'macho' else (0, 0)
    all_fma += fma
    all_insns += insns
    syms = run(['xcrun', 'nm', '-U', '-j', p])
    by_symbol = SIM_SYM.search(syms) is not None
    src = compiled_from.get(os.path.basename(p), '')
    if src or by_symbol:
        sim_rows.append((src or '(metadata/other)', os.path.basename(p), k, insns, fma, by_symbol))
ev['ALL_IL2CPP_OBJECTS'] = len(objects)
ev['ALL_IL2CPP_OBJECT_KINDS'] = ','.join(sorted(kinds)) or 'none'
ev['ALL_IL2CPP_INSTRUCTIONS'] = all_insns
ev['ALL_IL2CPP_FMA'] = all_fma
ev['SIM_CORE_OBJECTS'] = len(sim_rows)
ev['SIM_CORE_OBJECTS_FROM_SIM_SOURCES'] = sum(1 for r in sim_rows if not r[0].startswith('('))
ev['SIM_CORE_INSTRUCTIONS'] = sum(r[3] for r in sim_rows)
ev['SIM_CORE_FMA'] = sum(r[4] for r in sim_rows)
ev['SIM_CORE_MISSING_OBJECTS'] = sum(1 for o in compiled_from if o not in by_name)
with open(os.path.join(out, 'sim-core-objects.txt'), 'w') as f:
    f.write('# sim-core objects: compiled from AtomUniverse.Sim*.cpp/.c (clang lines) or defining (DetMath|DetProbe)_ symbols\n')
    f.write('# source object kind instructions fma has_sim_symbols\n')
    for r in sorted(sim_rows):
        f.write('source=%s object=%s kind=%s instructions=%d fma=%d sim_symbols=%s\n' % (
            r[0], r[1], r[2], r[3], r[4], 'yes' if r[5] else 'no'))

# (c) Linked binary: FMA inside functions whose symbol names come from the sim core.
binary = ''
for cand in (os.path.join(app, 'Frameworks', 'UnityFramework.framework', 'UnityFramework'),):
    if os.path.isfile(cand):
        binary = cand
if binary:
    funcs = fma = insns = 0
    in_sim = False
    proc = subprocess.Popen(['xcrun', 'objdump', '-d', '--no-show-raw-insn', binary], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, errors='replace')
    for l in proc.stdout:
        if l.endswith(':\n') and '<' in l:
            in_sim = SIM_SYM.search(l) is not None
            funcs += in_sim
            continue
        if in_sim:
            m = INSN.match(l)
            if m:
                insns += 1
                fma += FMA.match(m.group(1)) is not None
    proc.wait()
    ev['LINKED_BINARY'] = os.path.relpath(binary, os.path.dirname(app))
    ev['LINKED_SIM_FUNCTIONS'] = funcs
    ev['LINKED_SIM_INSTRUCTIONS'] = insns
    ev['LINKED_SIM_FMA'] = fma
else:
    ev['LINKED_BINARY'] = 'none'

# (d) Positive control and toolchain.
def count_fma(path):
    return objdump_counts(path)[1]
ev['CONTROL_FMA_DEFAULT'] = count_fma(os.path.join(control, 'default.o'))
ev['CONTROL_FMA_OFF'] = count_fma(os.path.join(control, 'off.o'))
driver = open(os.path.join(control, 'driver.txt'), errors='replace').read()
m = re.findall(r'"-ffp-contract=(\w+)"', driver)
ev['CLANG_DEFAULT_FP_CONTRACT'] = m[-1] if m else 'not-passed'
ev['CLANG_VERSION'] = run(['xcrun', 'clang', '--version']).splitlines()[0]
ev['APP_PATH'] = app
ev['APP_NAME'] = os.path.basename(app)

with open(os.path.join(out, 'evidence.txt'), 'a') as f:
    for k, v in ev.items():
        f.write('%s=%s\n' % (k, v))
PY

{
  echo "SDK=$xsdk"
  echo "XCODE_VERSION=$xcode_version"
  echo "BUILD_SECONDS=$seconds"
} >>"$evidence"
cat "$evidence"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  while IFS='=' read -r key value; do
    printf '%s=%s\n' "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" "$value"
  done <"$evidence" >>"$GITHUB_OUTPUT"
fi

value_of() { sed -n "s/^$1=//p" "$evidence" | tail -n 1; }
[ "$(value_of SIM_CORE_OBJECTS)" != 0 ] || die "no sim-core object files found below $dd"
if [ "$(value_of SIM_CORE_CLANG_LINES)" = 0 ]; then
  echo "::warning::no clang command lines for AtomUniverse.Sim*.cpp found in the xcodebuild log or Bee's DAG"
fi
if [ "$(value_of CONTROL_FMA_DEFAULT)" = 0 ]; then
  echo "::warning::the positive control a*b+c produced no FMA with the default flags, the FMA count proves little"
fi
