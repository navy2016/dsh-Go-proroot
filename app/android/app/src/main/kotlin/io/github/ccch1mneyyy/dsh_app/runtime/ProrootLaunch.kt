package io.github.ccch1mneyyy.dsh_app.runtime

/**
 * coderredlab/proroot backend: a drop-in proot replacement that translates guest paths with
 * LD_PRELOAD and binary patching instead of ptrace. The binaries are proprietary and shipped
 * unmodified (see runtime build and THIRD_PARTY_NOTICES). Its CLI is a subset of proot's, so
 * the launch template written by rtbuild.py needs converting: `--rootfs=`/`--cwd=` become
 * `-r`/`-w`, and `--kill-on-exit`, `--sysvipc`, `-L` are dropped (proroot has no tracee
 * model). `-0`, `--link2symlink` and `-b` are shared. The guest command is untouched.
 */
object ProrootLaunch {
    const val BACKEND = "proroot"
    const val LAUNCHER = "libproroot.so"
    /** Companion binaries expected next to the launcher (the runtime build pins them). */
    const val RUNTIME = "libproroot-runtime.so"
    const val STUB_LOADER = "libproroot-stub-loader.so"
    /** Entry adapter: the compat shims come from DSH-APP/DSHA (MIT), see runtime build. */
    const val LINKER_ADAPTER = "libdsha-proroot-linker.so"

    private val DROPPED = setOf("--kill-on-exit", "--sysvipc", "-L")

    /** proroot takes host:guest only; proot also accepts a bare path meaning host=guest. */
    fun bindValue(value: String): String = if (':' in value) value else "$value:$value"

    /**
     * Convert the manifest's proot launch argv, everything up to the first "/usr/bin/env",
     * into a proroot-compatible prefix. Placeholders such as {ROOTFS} are kept; DshProcess
     * expands them afterwards exactly as for proot.
     */
    fun convert(argv: List<String>): List<String> {
        val envAt = argv.indexOf("/usr/bin/env")
        if (envAt < 1) return argv
        val proot = argv.take(envAt)
        val out = ArrayList<String>(proot.size)
        var at = 0
        while (at < proot.size) {
            when (val arg = proot[at]) {
                in DROPPED -> at++
                "--link2symlink", "-0" -> {
                    out += arg
                    at++
                }
                "-b", "--bind" -> {
                    val value = proot.getOrNull(at + 1) ?: error("proroot engine: missing value after $arg")
                    out += arg
                    out += bindValue(value)
                    at += 2
                }
                else -> {
                    when {
                        arg.startsWith("--rootfs=") -> {
                            out += "-r"
                            out += arg.substringAfter('=')
                        }
                        arg.startsWith("--cwd=") -> {
                            out += "-w"
                            out += arg.substringAfter('=')
                        }
                        arg.startsWith("--bind=") -> {
                            out += "--bind=" + bindValue(arg.substringAfter('='))
                        }
                        else -> out += arg
                    }
                    at++
                }
            }
        }
        if (out.isNotEmpty() && out[0].substringAfterLast('/') == "libproot.so") {
            out[0] = out[0].substringBeforeLast('/') + "/" + LAUNCHER
        }
        return out + argv.drop(envAt)
    }
}
