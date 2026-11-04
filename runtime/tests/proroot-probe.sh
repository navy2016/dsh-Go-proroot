#!/system/bin/sh
# Run with /system/bin/sh from the app's terminal. No root or API key is needed.
# Usage: /system/bin/sh /path/proroot-probe.sh [https-url] [native-lib-dir] [rootfs]
set -eu

url=${1-}
runtime_lib=${PROROOT_LIB_PATH-}
lib=${2-${runtime_lib%/*}}
root=${3-${PROROOT_ROOTFS-${DSH_GO_RUNTIME_ROOT-}}}
toybox=/system/bin/toybox
if [ ! -x "$toybox" ]; then
    echo 'ERROR: run this on Android with /system/bin/sh, not inside a desktop container.' >&2
    exit 2
fi
if [ -z "$lib" ] || [ -z "$root" ]; then
    echo 'ERROR: missing native library directory or rootfs; supply arguments 2 and 3 from the launch log.' >&2
    exit 2
fi
case "$lib" in /data/app/*/lib/arm64) ;; *) echo 'ERROR: unexpected native library directory.' >&2; exit 2 ;; esac
case "$root" in /data/user/*/*/files/runtime/rootfs|/data/data/*/files/runtime/rootfs) ;; *) echo 'ERROR: unexpected rootfs path.' >&2; exit 2 ;; esac
for name in libproroot.so libproroot-runtime.so libproroot-stub-loader.so libproroot-bridge.so libproroot-linker.so libdsha-proroot-compat.so libdsha-proroot-linker.so; do
    if [ ! -r "$lib/$name" ]; then
        echo "ERROR: cannot read $name at the supplied directory; use the current APK's launch log." >&2
        exit 2
    fi
done
if [ ! -d "$root/etc" ]; then
    echo 'ERROR: cannot read this app rootfs from this terminal.' >&2
    exit 2
fi

printf '=== installed library SHA256 (compare with pinned originals) ===\n'
"$toybox" sha256sum "$lib"/*proroot*.so

# Inspect the caller, not /proc/self of an external grep process.
printf '=== caller shell pid=%s ===\n' "$PPID"
if [ -r "/proc/$PPID/maps" ]; then
    "$toybox" grep -c proroot "/proc/$PPID/maps" || :
else
    echo 'maps: permission denied or caller exited'
fi
for fd in "${PROROOT_CFG_FD-}" "${PROROOT_ESCAPE_FD-}"; do
    case "$fd" in ''|*[!0-9]*) echo 'caller config fd: not set' ;; *)
        if [ -e "/proc/$PPID/fd/$fd" ]; then echo "caller config fd $fd: open"; else echo "caller config fd $fd: closed or inaccessible"; fi ;;
    esac
done

cache=${root%/files/runtime/rootfs}/cache
probe_tmp=$cache/proroot-probe
"$toybox" mkdir -p "$probe_tmp"
# Android mksh creates here-document files before executing the command's env assignments.
export TMPDIR="$probe_tmp"
# Only loader scratch files go here. Do not modify the running engine or guest configuration.
for mode in static dynamic; do
    printf '\n=== fresh proroot %s ===\n' "$mode"
    if [ "$mode" = static ]; then loader=--static-loader; else loader=--no-static-loader; fi
    rc=0
    set -- "$toybox" env -i \
        PATH=/system/bin HOME="$cache" TMPDIR="$probe_tmp" \
        ANDROID_ROOT=/system ANDROID_DATA=/data \
        PROROOT_TMP_DIR="$probe_tmp" \
        PROROOT_LIB_PATH="$lib/libproroot-runtime.so" \
        PROROOT_LINKER_PATH="$lib/libdsha-proroot-linker.so"
    if [ "$mode" = static ]; then set -- "$@" "PROROOT_STUB_LOADER=$lib/libproroot-stub-loader.so"; fi
    "$toybox" timeout -s KILL 45 "$@" \
        "$lib/libproroot.so" "$loader" -r "$root" -0 -w /root \
        -b /dev:/dev -b /dev/urandom:/dev/random -b /proc:/proc \
        -b /proc/self/fd:/dev/fd -b /proc/self/fd/0:/dev/stdin \
        -b /proc/self/fd/1:/dev/stdout -b /proc/self/fd/2:/dev/stderr \
        -b /sys:/sys -b "$root/var/lib/dsh-app/empty:/sys/fs/selinux" \
        -b "$root/var/lib/dsh-app/shm:/dev/shm" -b /system:/system -b /apex:/apex \
        --link2symlink /usr/bin/env \
        HOME=/root USER=root LOGNAME=root SHELL=/bin/bash \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LANG=C.UTF-8 TERM=xterm-256color TMPDIR=/tmp UV_USE_IO_URING=0 \
        NODE_OPTIONS=--dns-result-order=ipv4first \
        /bin/sh -c 'exec /opt/node/bin/node --input-type=module - "$@"' probe "$url" <<'JS' || rc=$?
import fs from 'node:fs';
import cp from 'node:child_process';
import dns from 'node:dns';
import https from 'node:https';
import { createRequire } from 'node:module';

const report = (name, value) => console.log(name + ': ' + JSON.stringify(value));
const errorCode = e => e?.code ?? e?.name ?? 'ERROR';
const attempt = fn => { try { return fn(); } catch (e) { return { error: errorCode(e) }; } };
const bounded = (promise, ms = 6000) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Object.assign(new Error(), { code: 'PROBE_TIMEOUT' })), ms);
    promise.then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
});
const fdState = Object.fromEntries(['PROROOT_CFG_FD', 'PROROOT_ESCAPE_FD'].map(key => {
    const fd = process.env[key];
    return [key, fd && /^\d+$/.test(fd) ? { fd, state: attempt(() => { const stat = fs.fstatSync(Number(fd)); return { dev: stat.dev, ino: stat.ino, mode: stat.mode }; }) } : 'unset'];
}));
report('node', { version: process.version, pid: process.pid, ppid: process.ppid, cwd: attempt(() => process.cwd()), fds: fdState });
report('node maps', attempt(() => fs.readFileSync(`/proc/${process.pid}/maps`, 'utf8').split('\n').filter(line => line.includes('proroot')).length));
report('guest os', attempt(() => fs.readFileSync('/etc/os-release', 'utf8').split('\n').filter(line => /^(ID|VERSION_ID)=/.test(line))));
report('resolv.conf', attempt(() => fs.readFileSync('/etc/resolv.conf', 'utf8').split('\n').filter(line => /^\s*(nameserver|options)\s/.test(line))));
report('host etc visible', fs.existsSync('/etc/NOTICE.xml.gz'));
report('physical root os', attempt(() => fs.readFileSync(`${process.env.PROROOT_ROOTFS}/etc/os-release`, 'utf8').split('\n').filter(line => /^(ID|VERSION_ID)=/.test(line))));

const shellProbe = 'printf "SHELL_PID=%s\\n" "$$"; ' +
    'for f in /etc/os-release /etc/resolv.conf; do if [ -r "$f" ]; then printf "READ_OK=%s\\n" "$f"; else printf "READ_FAIL=%s\\n" "$f"; fi; done; ' +
    'printf "CFG=%s ESCAPE=%s\\n" "${PROROOT_CFG_FD-unset}" "${PROROOT_ESCAPE_FD-unset}"; ' +
    'for fd in "${PROROOT_CFG_FD-}" "${PROROOT_ESCAPE_FD-}"; do case "$fd" in ""|*[!0-9]*) ;; *) ' +
    'if [ -e "/proc/$$/fd/$fd" ]; then printf "FD_OPEN=%s\\n" "$fd"; else printf "FD_CLOSED=%s\\n" "$fd"; fi ;; esac; done; ' +
    'for fd in "${PROROOT_CFG_FD-}" "${PROROOT_ESCAPE_FD-}"; do case "$fd" in ""|*[!0-9]*) ;; *) ' +
    '/system/bin/toybox stat -L -c "FD_META=%d:%i:%f" "/proc/$$/fd/$fd"; ' +
    '/system/bin/toybox grep "^flags:" "/proc/$$/fdinfo/$fd"; esac; done; ' +
    'printf "SHELL_MAPS="; /system/bin/toybox grep -c proroot /proc/$$/maps; ' +
    'printf "NODE_PATH="; command -v node; pwd; printf "PROBE_SHELL_DONE\\n"';
const spawned = cp.spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', shellProbe], {
    cwd: '/root', env: { ...process.env }, timeout: 5000, encoding: 'utf8', maxBuffer: 8192,
});
report('spawnSync', { status: spawned.status, signal: spawned.signal, error: spawned.error && errorCode(spawned.error), stdout: spawned.stdout, stderr: spawned.stderr });

try {
    const require = createRequire('/opt/dsh/package.json');
    const pty = require('node-pty');
    const result = await new Promise(resolve => {
        let output = '', finished = false;
        const terminal = pty.spawn('/bin/bash', ['--noprofile', '--norc', '-c', shellProbe], {
            cwd: '/root', env: { ...process.env }, name: 'xterm', cols: 120, rows: 30,
        });
        const timer = setTimeout(() => {
            finished = true;
            try { terminal.kill('SIGKILL'); } catch {}
            resolve({ error: 'PROBE_TIMEOUT', output });
        }, 5000);
        terminal.onData(data => { output = (output + data).slice(-8192); });
        terminal.onExit(({ exitCode, signal }) => {
            if (finished) return;
            clearTimeout(timer);
            resolve({ status: exitCode, signal, output });
        });
    });
    report('node-pty', result);
} catch (e) { report('node-pty', { error: errorCode(e) }); }

const supplied = process.argv[2];
if (!supplied) {
    report('network', 'skipped: no HTTPS URL supplied');
} else {
    let url;
    try {
        url = new URL(supplied);
        if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new Error();
    } catch {
        report('network', { error: 'USE_HTTPS_URL_WITHOUT_CREDENTIALS_OR_QUERY' });
        process.exit(2);
    }
    const lookup = fn => bounded(new Promise((resolve, reject) => fn(url.hostname, { all: true }, (error, addresses) => {
        if (error) reject(error); else resolve({ count: addresses.length, families: [...new Set(addresses.map(a => a.family))] });
    })));
    const request = resolver => new Promise(resolve => {
        // A 401/403/404 still proves DNS + TCP + TLS + HTTP completed. Never send a key or print a body.
        const req = https.get(url, { ...(resolver ? { lookup: resolver } : {}), headers: { 'User-Agent': 'dsh-go-proroot-probe' } }, res => {
            clearTimeout(timer);
            report('HTTP status', res.statusCode);
            res.destroy();
            resolve({ status: res.statusCode });
        });
        const timer = setTimeout(() => req.destroy(Object.assign(new Error(), { code: 'PROBE_TIMEOUT' })), 8000);
        req.on('error', e => { clearTimeout(timer); resolve({ error: errorCode(e), cause: e.cause && errorCode(e.cause) }); });
    });
    try { report('native DNS', await lookup(dns.lookup)); } catch (e) { report('native DNS', { error: errorCode(e) }); }
    report('native HTTPS', await request());
    let adapter;
    try {
        const { createLookup } = await import('/opt/dsh-go/direct/dns.mjs');
        adapter = createLookup({ resolvConf: '/etc/resolv.conf', hostsFile: '/etc/hosts', watch: false });
        try { report('app DNS adapter', await lookup(adapter.lookup)); } catch (e) { report('app DNS adapter', { error: errorCode(e) }); }
        report('app HTTPS adapter', await request(adapter.lookup));
    } catch (e) { report('app DNS adapter init', { error: errorCode(e) }); }
    finally { adapter?.close(); }
}
// c-ares may retain a pending timed-out query; the probe owns no engine process.
process.exit(0);
JS
    printf '=== %s launcher exit=%s ===\n' "$mode" "$rc"
done
