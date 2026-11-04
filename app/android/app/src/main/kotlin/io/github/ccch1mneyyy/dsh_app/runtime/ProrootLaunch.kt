package io.github.ccch1mneyyy.dsh_app.runtime

/**
 * coderredlab/proroot backend: a drop-in proot replacement that translates guest paths with
 * LD_PRELOAD and binary patching instead of ptrace. The binaries are proprietary and shipped
 * unmodified (see runtime build and THIRD_PARTY_NOTICES).
 *
 * proroot's CLI is a subset of proot's, so the launch template written by rtbuild.py is rebuilt
 * instead of patched in place: `--static-loader` leads, `--rootfs=`/`--cwd=` become `-r`/`-w`,
 * every `-b` becomes host:guest, and proot-only flags (`--kill-on-exit`, `--sysvipc`, `-L`) are
 * left out. The guest command and environment are untouched.
 */
object ProrootLaunch {
    const val BACKEND = "proroot"
    const val LAUNCHER = "libproroot.so"
    /** Companion binaries expected next to the launcher (the runtime build pins them). */
    const val RUNTIME = "libproroot-runtime.so"
    const val STUB_LOADER = "libproroot-stub-loader.so"
    /** Entry adapter: the compat shims come from DSH-APP/DSHA (MIT), see runtime build. */
    const val LINKER_ADAPTER = "libdsha-proroot-linker.so"

    /** proroot takes host:guest only; proot also accepts a bare path meaning host=guest. */
    fun bindValue(value: String): String = if (':' in value) value else "$value:$value"

    /**
     * Rebuild the launch for proroot: its CLI is a subset of proot's, and the vendor's own
     * Android examples put `--static-loader` first and every bind in host:guest form. Keeping
     * proot's argument order (or leaving an adaptive stub-loader guess) is what we tried first,
     * and the guest came up without the rootfs path view at all.
     */
    fun convert(argv: List<String>): List<String> {
        val envAt = argv.indexOf("/usr/bin/env")
        if (envAt < 1) return argv
        val proot = argv.take(envAt)
        val first = proot.firstOrNull() ?: return argv
        if (first.substringAfterLast('/') != "libproot.so") return argv

        var root: String? = null
        var cwd: String? = null
        val binds = ArrayList<String>()
        var link2symlink = false
        var at = 1
        while (at < proot.size) {
            val arg = proot[at]
            when {
                arg == "-r" || arg == "--rootfs" -> {
                    root = proot.getOrNull(at + 1) ?: error("proroot engine: missing value after $arg")
                    at += 2
                }
                arg.startsWith("--rootfs=") -> {
                    root = arg.substringAfter('=')
                    at++
                }
                arg == "-w" || arg == "--cwd" -> {
                    cwd = proot.getOrNull(at + 1) ?: error("proroot engine: missing value after $arg")
                    at += 2
                }
                arg.startsWith("--cwd=") -> {
                    cwd = arg.substringAfter('=')
                    at++
                }
                arg == "-b" || arg == "--bind" -> {
                    binds += bindValue(proot.getOrNull(at + 1) ?: error("proroot engine: missing value after $arg"))
                    at += 2
                }
                arg.startsWith("--bind=") -> {
                    binds += bindValue(arg.substringAfter('='))
                    at++
                }
                arg == "--link2symlink" -> {
                    link2symlink = true
                    at++
                }
                else -> at++
            }
        }
        val rootPath = root ?: return argv

        val tail = argv.drop(envAt).toMutableList()
        // proroot hands its path-translation hooks to the guest through the process environment
        // (the launcher preloads its runtime library). `env -i` is right for proot, which would
        // otherwise leak the Android environment, but here it wipes those hooks before the guest
        // starts: every lookup then lands on the host filesystem — /etc showed Android's files and
        // node was missing, while dsh still started because --static-loader routes exec itself.
        if (tail.getOrNull(1) == "-i" || tail.getOrNull(1) == "--ignore-environment") tail.removeAt(1)

        return buildList {
            add(first.substringBeforeLast('/') + "/" + LAUNCHER)
            add("--static-loader")
            add("-r")
            add(rootPath)
            add("-0")
            cwd?.let {
                add("-w")
                add(it)
            }
            for (bind in binds) {
                add("-b")
                add(bind)
            }
            if (link2symlink) add("--link2symlink")
            addAll(tail)
        }
    }
}
