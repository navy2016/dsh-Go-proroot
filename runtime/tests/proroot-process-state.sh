#!/system/bin/sh
# Read metadata from the existing failed process, without launching another engine.
set -u
T=/system/bin/toybox
if [ "${1-}" != --host ]; then
    root=${PROROOT_ROOTFS-${DSH_GO_RUNTIME_ROOT-}}
    cfg=${PROROOT_CFG_FD-}
    escape=${PROROOT_ESCAPE_FD-}
    case "$root" in /data/user/*/*/files/runtime/rootfs|/data/data/*/files/runtime/rootfs) ;;
        *) echo 'ERROR: missing app rootfs; run from the affected terminal.' >&2; exit 2 ;; esac
    case "$cfg" in
        "${root%/files/runtime/rootfs}"/cache/*/.proroot-config-*|"${root%/files/runtime/rootfs}"/no_backup/proroot/.proroot-config-*) ;;
        *) echo 'ERROR: unexpected proroot config path.' >&2; exit 2 ;; esac
    exec "$T" env -i PATH=/system/bin "/system/bin/sh" "$0" --host "$PPID" "$root" "$cfg" "$escape"
fi
caller=$2
root=$3
cfg=$4
escape=$5
case "$caller" in ''|*[!0-9]*) echo 'ERROR: invalid caller PID' >&2; exit 2 ;; esac
printf '=== existing proroot process metadata ===\n'
printf 'collector PID=%s original shell=%s\n' "$$" "$caller"
printf 'collector proroot mappings: '
"$T" grep -c proroot "/proc/$$/maps" || :
printf '\n=== physical rootfs and inherited config ===\n'
"$T" stat -L -c 'file=%n type=%F dev=%d ino=%i size=%s' "$root/etc/os-release" "$cfg" 2>&1 || :

snapshot() {
    p=$1
    label=$2
    printf '\n=== %s PID=%s ===\n' "$label" "$p"
    parent=
    if [ ! -r "/proc/$p/status" ]; then
        echo 'status unavailable (exited or permission denied)'
        return
    fi
    while IFS= read -r line; do
        case "$line" in Name:*|State:*|PPid:*|Uid:*) printf '%s\n' "$line" ;; esac
        case "$line" in PPid:*) parent=${line#PPid:}; parent=${parent##*[!0-9]} ;; esac
    done < "/proc/$p/status"
    if IFS= read -r statline < "/proc/$p/stat"; then
        fields=${statline##*) }
        set -- $fields
        if [ "$#" -ge 20 ]; then shift 19; printf 'starttime_ticks=%s\n' "$1"; fi
    fi
    printf 'kernel root: '; "$T" readlink "/proc/$p/root" 2>&1 || :
    printf 'kernel cwd: '; "$T" readlink "/proc/$p/cwd" 2>&1 || :
    if [ -r "/proc/$p/maps" ]; then
        while IFS= read -r line; do
            case "$line" in *proroot*) printf '%s\n' "$line" ;; esac
        done < "/proc/$p/maps"
    else
        echo 'maps unavailable'
    fi
    case "$escape" in ''|*[!0-9]*) ;;
        *) printf 'inherited escape FD=%s\n' "$escape"
           "$T" readlink "/proc/$p/fd/$escape" 2>&1 || :
           "$T" stat -L -c 'escape type=%F dev=%d ino=%i mode=%f' "/proc/$p/fd/$escape" 2>&1 || : ;;
    esac
    printf 'config through target kernel root:\n'
    "$T" stat -L -c 'file=%n type=%F dev=%d ino=%i size=%s' "/proc/$p/root$cfg" 2>&1 || :
}

seen=' '
p=$caller
for depth in 1 2 3 4; do
    case "$p" in ''|0|1|*[!0-9]*) break ;; esac
    case "$seen" in *" $p "*) break ;; esac
    seen="$seen$p "
    snapshot "$p" "parent-chain $depth"
    p=$parent
done
pidfile="$root/tmp/dsh-web.pid"
if [ ! -L "$pidfile" ] && [ -f "$pidfile" ] && [ -r "$pidfile" ]; then
    IFS= read -r engine < "$pidfile" || :
    case "${engine-}" in ''|0|1|*[!0-9]*) echo 'engine pid file has no valid PID' ;;
        *) case "$seen" in *" $engine "*) echo 'engine PID already included in parent chain' ;;
            *) snapshot "$engine" 'engine PID file' ;; esac ;;
    esac
else
    echo 'engine PID file skipped: not a readable regular file or is a symlink'
fi
printf '\n=== end (no environ, command line, config contents or log contents read) ===\n'
