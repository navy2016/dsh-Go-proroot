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

printf '=== proroot probe v6 ===\n'
printf '=== installed library SHA256 (compare with pinned originals) ===\n'
"$toybox" sha256sum "$lib"/*proroot*.so

# Inspect the caller, not /proc/self of an external grep process.
printf '=== caller shell pid=%s ===\n' "$PPID"
case "${PROROOT_ESCAPE_FD-}" in
    ''|*[!0-9]*) ;;
    *) "$toybox" readlink "/proc/$PPID/fd/$PROROOT_ESCAPE_FD" || :
       "$toybox" stat -L -c 'caller escape: type=%F dev=%d ino=%i mode=%f' "/proc/$PPID/fd/$PROROOT_ESCAPE_FD" || : ;;
esac
if [ -r "/proc/$PPID/maps" ]; then
    "$toybox" grep -c proroot "/proc/$PPID/maps" || :
else
    echo 'maps: permission denied or caller exited'
fi
for control in "${PROROOT_CFG_FD-}" "${PROROOT_ESCAPE_FD-}"; do
    case "$control" in
        '') echo 'caller control: unset' ;;
        /*) if [ -r "$control" ]; then echo "caller config file: readable ($control)"; else echo "caller config file: unreadable ($control)"; fi ;;
        *[!0-9]*) echo 'caller control: unrecognized value' ;;
        *) if [ -e "/proc/$PPID/fd/$control" ]; then echo "caller fd $control: open"; else echo "caller fd $control: closed or inaccessible"; fi ;;
    esac
done

cache=${root%/files/runtime/rootfs}/cache
probe_tmp=$cache/proroot-probe
"$toybox" mkdir -p "$probe_tmp"
# Android mksh creates here-document files before executing the command's env assignments.
export TMPDIR="$probe_tmp"
# Only loader scratch files go here. Do not modify the running engine or guest configuration.
modes='static dynamic'
if [ "${PROROOT_PROBE_FD_LAYOUTS-}" = 1 ]; then modes='fd-low fd-reserved'; url=; fi
if [ "${PROROOT_PROBE_DSH_SERVICE-}" = 1 ]; then modes='dsh-service dsh-service-fallback'; url=; fi
if [ "${PROROOT_PROBE_DSH_BOOT-}" = 1 ]; then modes='dsh-service-boot dsh-service-boot-uncached'; url=; fi
for mode in $modes; do
    printf '\n=== fresh proroot %s ===\n' "$mode"
    if [ "$mode" = dynamic ]; then loader=--no-static-loader; else loader=--static-loader; fi
    rc=0
    set -- "$toybox" env -i \
        PATH=/system/bin HOME="$cache" TMPDIR="$probe_tmp" \
        ANDROID_ROOT=/system ANDROID_DATA=/data \
        PROROOT_TMP_DIR="$probe_tmp" \
        PROROOT_LIB_PATH="$lib/libproroot-runtime.so" \
        PROROOT_LINKER_PATH="$lib/libdsha-proroot-linker.so"
    if [ "$mode" != dynamic ]; then set -- "$@" "PROROOT_STUB_LOADER=$lib/libproroot-stub-loader.so"; fi
    if [ "$mode" = dsh-service-boot-uncached ]; then set -- "$@" NARB_DISABLE_NATIVE_CACHE=1; fi
    # env treats APK paths containing '=' as assignments; let a fixed shell path exec the argv.
    "$toybox" timeout -s KILL 75 "$@" \
        /system/bin/sh -c '
            layout=$1; shift
            case "$layout" in
                fd-low) exec 3<&- 4<&- 5<&- 6<&- 7<&- 8<&- 9<&- ;;
                fd-reserved) exec 3</dev/null 4</dev/null 5</dev/null 6</dev/null 7</dev/null 8</dev/null 9</dev/null ;;
            esac
            exec "$@"
        ' proroot-probe "$mode" \
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
        /bin/sh -c 'exec /opt/node/bin/node --input-type=module - "$@"' probe "$url" "$mode" <<'JS' || rc=$?
import fs from 'node:fs';
import cp from 'node:child_process';
import dns from 'node:dns';
import https from 'node:https';
import { createRequire } from 'node:module';
import os from 'node:os';

const report = (name, value) => console.log(name + ': ' + JSON.stringify(value));
const errorCode = e => e?.code ?? e?.name ?? 'ERROR';
const attempt = fn => { try { return fn(); } catch (e) { return { error: errorCode(e) }; } };
const bounded = (promise, ms = 6000) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Object.assign(new Error(), { code: 'PROBE_TIMEOUT' })), ms);
    promise.then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
});
const fdState = Object.fromEntries(['PROROOT_CFG_FD', 'PROROOT_ESCAPE_FD'].map(key => {
    const fd = process.env[key];
    if (!fd) return [key, 'unset'];
    if (/^\d+$/.test(fd)) return [key, { fd, state: attempt(() => { const stat = fs.fstatSync(Number(fd)); return { dev: stat.dev, ino: stat.ino, mode: stat.mode }; }) }];
    return [key, { path: fd, state: attempt(() => { fs.accessSync(fd, fs.constants.R_OK); return 'readable'; }) }];
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
    'case "${PROROOT_CFG_FD-}" in /*) if [ -r "$PROROOT_CFG_FD" ]; then printf "CFG_FILE_READABLE\\n"; else printf "CFG_FILE_UNREADABLE\\n"; fi ;; esac; ' +
    'maps=0; while IFS= read -r line; do case "$line" in *proroot*) maps=$((maps + 1));; esac; done < /proc/$$/maps; ' +
    'printf "SHELL_MAPS=%s\\n" "$maps"; ' +
    'case "${PROROOT_ESCAPE_FD-}" in ""|*[!0-9]*) printf "ESCAPE_DIRECTORY=unknown\\n" ;; *) ' +
    'if [ -d "/proc/$$/fd/$PROROOT_ESCAPE_FD" ]; then printf "ESCAPE_DIRECTORY=yes\\n"; else printf "ESCAPE_DIRECTORY=no\\n"; fi ;; esac; ' +
    'printf "NODE_PATH="; command -v node; pwd; printf "PROBE_SHELL_DONE\\n"';
if (process.argv[3]?.startsWith('dsh-service')) {
    const snapshot = name => report(name, attempt(() => {
        const fd = Number(process.env.PROROOT_ESCAPE_FD);
        const stat = fs.fstatSync(fd);
        return { fd, directory: stat.isDirectory(), dev: stat.dev, ino: stat.ino,
            target: fs.readlinkSync(`/proc/${process.pid}/fd/${fd}`),
            guestEtc: fs.existsSync('/etc/os-release') };
    }));
    let runtime, context, bootDir;
    let cleanupComplete = true;
    try {
        snapshot('before DSH module import');
        const { Context } = await import('/opt/dsh/node_modules/@deepseek-ai/cordis/lib/index.js');
        context = new Context();
        if (process.argv[3].startsWith('dsh-service-boot')) {
            bootDir = fs.mkdtempSync('/tmp/proroot-boot-probe-');
            report('native cache disabled', process.env.NARB_DISABLE_NATIVE_CACHE === '1');
            snapshot('before app-boot import');
            const { PluginPackages } = await import('/opt/dsh/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js');
            snapshot('before PluginPackages interception');
            new PluginPackages(context, { resolution: { profilesDir: `${bootDir}/profiles`, profileDir: undefined,
                entries: [], localPackageNames: [], linkedRoots: [] } });
            snapshot('after PluginPackages interception');
        }
        const { default: Runtime } = await import('/opt/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js');
        snapshot('after DSH module import');
        runtime = new Runtime(context);
        snapshot('after DSH service construction');
        if (process.argv[3] === 'dsh-service-fallback') {
            runtime.linuxScope.select = () => ({ kind: 'fallback', reason: 'diagnostic control: skip manager probe' });
        }
        const select = runtime.selectContainmentMode.bind(runtime);
        runtime.selectContainmentMode = kind => {
            snapshot('before containment selection');
            const result = select(kind);
            report('DSH containment', { kind, result });
            snapshot('after containment selection');
            return result;
        };
        const metadata = output => output.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '').split(/\r?\n/)
            .filter(line => /^(SHELL_PID=|READ_OK=|READ_FAIL=|CFG=|FD_OPEN=|FD_CLOSED=|CFG_FILE_|SHELL_MAPS=|ESCAPE_DIRECTORY=|NODE_PATH=|PROBE_SHELL_DONE$|\/root(?:\/|$)|shell-init:)/.test(line)).join('\n');
        for (const shellActivity of [false, true]) {
            const label = `DSH terminal shellActivity=${shellActivity}`;
            let terminal, output = '', cleanupFailed = false;
            try {
                snapshot(`${label} before spawn`);
                terminal = await bounded(runtime.spawnTerminal({ argv: ['/bin/bash', '-i'], cwd: '/root/workspace',
                    env: { PS1: '__DSH_PROBE__ ' }, terminalType: 'xterm', rows: 30, cols: 120,
                    graceMs: 500, shellActivity }), 12000);
                terminal.done.catch(() => {});
                terminal.output.on('data', data => { output = (output + data.toString()).slice(-12000); });
                snapshot(`${label} after spawn`);
                await bounded(terminal.write(`${shellProbe}; exit\n`), 3000);
                const outcome = await bounded(terminal.done, 8000);
                report(label, { pid: terminal.pid, outcome, output: metadata(output) });
                snapshot(`${label} after exit`);
            } catch (error) {
                report(label, { error: errorCode(error), output: metadata(output) });
            } finally {
                if (terminal) {
                    try { await bounded(terminal.terminate(), 5000); }
                    catch (error) {
                        cleanupFailed = true;
                        cleanupComplete = false;
                        runtime.terminateForHostExit();
                        report(`${label} cleanup`, { error: errorCode(error), exitUnconfirmed: true });
                    }
                }
            }
            if (cleanupFailed) break;
        }
    } catch (error) { report('DSH service probe', { error: errorCode(error) }); }
    finally {
        if (runtime) {
            try { await bounded(runtime.disposeManagedProcesses(), 5000); }
            catch (error) { cleanupComplete = false; runtime.terminateForHostExit(); report('DSH cleanup', { error: errorCode(error) }); }
        }
        if (context) {
            try { await bounded(context.fiber.dispose(), 5000); }
            catch (error) { cleanupComplete = false; report('context cleanup', { error: errorCode(error) }); }
        }
        if (bootDir && cleanupComplete) fs.rmSync(bootDir, { recursive: true, force: true });
        else if (bootDir) report('retained probe directory', bootDir);
    }
    process.exit(0);
}

const spawned = cp.spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', shellProbe], {
    cwd: '/root', env: { ...process.env }, timeout: 5000, encoding: 'utf8', maxBuffer: 8192,
});
report('spawnSync', { status: spawned.status, signal: spawned.signal, error: spawned.error && errorCode(spawned.error), stdout: spawned.stdout, stderr: spawned.stderr });

const fdLayoutProbe = process.argv[3]?.startsWith('fd-');
if (fdLayoutProbe) {
    const controlled = cp.spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', shellProbe], {
        cwd: '/root', env: { ...process.env }, timeout: 5000, encoding: 'utf8', maxBuffer: 8192,
        stdio: ['pipe', 'pipe', 'pipe', 'ignore', 'ignore', 'ignore', 'ignore', 'pipe'],
    });
    report('spawnSync DSH control layout', { status: controlled.status, signal: controlled.signal, error: controlled.error && errorCode(controlled.error), stdout: controlled.stdout, stderr: controlled.stderr });
}
let activityDir;
let ptyExitConfirmed = true;
try {
    const require = createRequire('/opt/dsh/package.json');
    const pty = require('node-pty');
    const cases = [{ name: 'node-pty inherited', env: { ...process.env }, cwd: '/root', interactive: false }];
    try {
        const { scrubbedParentEnv } = await import('/opt/dsh/node_modules/@deepseek-ai/dsh-subprocess/lib/index.js');
        const clean = scrubbedParentEnv();
        report('DSH removed env names', Object.keys(process.env).filter(key => !(key in clean)));
        if (!fdLayoutProbe) cases.push(
            { name: 'node-pty DSH env', env: clean, cwd: '/root', interactive: false },
            { name: 'node-pty DSH interactive', env: clean, cwd: '/root', interactive: true },
            { name: 'node-pty DSH workspace', env: clean, cwd: '/root/workspace', interactive: true },
        );
    } catch (e) { report('DSH environment probe', { error: errorCode(e) }); }
    if (fdLayoutProbe) {
        activityDir = fs.mkdtempSync('/tmp/proroot-prompt-probe-');
        const rc = `${activityDir}/bashrc`;
        const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
        fs.writeFileSync(rc, [
            '__proroot_probe_prompt() {',
            `  builtin trap -p >| ${quote(`${activityDir}/guards`)}`,
            `  builtin printf '%s:idle\\n' "$BASHPID" >| ${quote(`${activityDir}/state`)}`,
            '}',
            'PROMPT_COMMAND=__proroot_probe_prompt',
            "PS1='__PROROOT_PROBE_READY__ '",
            '',
        ].join('\n'), { mode: 0o600 });
        cases.push({ name: 'node-pty prompt redirections', env: { ...process.env }, cwd: '/root/workspace', args: ['--rcfile', rc, '-i'], waitForPrompt: true });
    }
    for (const entry of cases) {
        const result = await new Promise(resolve => {
            let output = '', finished = false, sent = false, timedOut = false, exitTimer;
            const args = entry.args ?? (entry.interactive ? ['-i', '-c', shellProbe] : ['--noprofile', '--norc', '-c', shellProbe]);
            const terminal = pty.spawn('/bin/bash', args, {
                cwd: entry.cwd, env: { ...entry.env }, name: 'xterm', cols: 120, rows: 30,
            });
            const timer = setTimeout(() => {
                timedOut = true;
                try { terminal.kill('SIGKILL'); } catch (error) {
                    finished = true;
                    ptyExitConfirmed = false;
                    resolve({ error: errorCode(error), exitUnconfirmed: true, output });
                    return;
                }
                exitTimer = setTimeout(() => {
                    finished = true;
                    ptyExitConfirmed = false;
                    resolve({ error: 'PTY_EXIT_UNCONFIRMED', output });
                }, 2000);
            }, 5000);
            terminal.onData(data => {
                output = (output + data).slice(-8192);
                if (entry.waitForPrompt && !sent && output.includes('__PROROOT_PROBE_READY__')) {
                    sent = true;
                    terminal.write(`${shellProbe}; exit\n`);
                }
            });
            terminal.onExit(({ exitCode, signal }) => {
                if (finished) return;
                finished = true;
                clearTimeout(timer);
                clearTimeout(exitTimer);
                resolve({ status: exitCode, signal, ...(timedOut ? { error: 'PROBE_TIMEOUT' } : {}), output });
            });
        }).catch(error => ({ error: errorCode(error) }));
        report(entry.name, result);
        if (!ptyExitConfirmed) break;
    }
} catch (e) { report('node-pty', { error: errorCode(e) }); }
finally {
    if (activityDir && ptyExitConfirmed) fs.rmSync(activityDir, { recursive: true, force: true });
    else if (activityDir) report('retained probe directory', activityDir);
}

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
    report('interfaces', attempt(() => Object.values(os.networkInterfaces()).flat().filter(Boolean).map(({ family, internal }) => ({ family, internal }))));
    const lookup = (fn, hints = 0) => bounded(new Promise((resolve, reject) => fn(url.hostname, { all: true, hints }, (error, addresses) => {
        if (error) reject(error); else resolve({ count: addresses.length, families: [...new Set(addresses.map(a => a.family))] });
    })));
    const request = resolver => new Promise(resolve => {
        // A 401/403/404 still proves DNS + TCP + TLS + HTTP completed. Never send a key or print a body.
        const observedLookup = (host, options, callback) => {
            report('HTTPS lookup options', options);
            (resolver ?? dns.lookup)(host, options, callback);
        };
        const req = https.get(url, { lookup: observedLookup, headers: { 'User-Agent': 'dsh-go-proroot-probe' } }, res => {
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
        try { report('app DNS ADDRCONFIG', await lookup(adapter.lookup, dns.ADDRCONFIG)); } catch (e) { report('app DNS ADDRCONFIG', { error: errorCode(e) }); }
        report('app HTTPS adapter', await request(adapter.lookup));
        const withoutAddrConfig = (host, options, callback) => adapter.lookup(host, { ...options, hints: (options.hints ?? 0) & ~dns.ADDRCONFIG }, callback);
        report('app HTTPS without ADDRCONFIG', await request(withoutAddrConfig));
    } catch (e) { report('app DNS adapter init', { error: errorCode(e) }); }
    finally { adapter?.close(); }
}
// c-ares may retain a pending timed-out query; the probe owns no engine process.
process.exit(0);
JS
    printf '=== %s launcher exit=%s ===\n' "$mode" "$rc"
done
