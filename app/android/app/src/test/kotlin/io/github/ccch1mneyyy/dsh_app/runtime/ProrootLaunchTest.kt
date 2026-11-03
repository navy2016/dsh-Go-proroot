package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test

/** The manifest launch template is written for proot; proroot accepts a subset of that CLI. */
class ProrootLaunchTest {
    private val template = listOf(
        "{NATIVE_LIB_DIR}/libproot.so",
        "--kill-on-exit", "--link2symlink", "--sysvipc", "-L", "-0",
        "--rootfs={ROOTFS}", "--cwd=/root",
        "-b", "/dev",
        "-b", "{ROOTFS}/var/lib/dsh-app/shm:/dev/shm",
        "/usr/bin/env", "-i", "HOME=/root", "/bin/sh", "-c",
        "echo \$\$ > /tmp/dsh-web.pid; exec /usr/local/bin/dsh web --port 3080 --no-open",
    )

    @Test fun convertsTheProotPrefixAndKeepsTheGuestSide() {
        val out = ProrootLaunch.convert(template)
        assertEquals("{NATIVE_LIB_DIR}/libproroot.so", out.first())
        // proroot has no tracee model: these three have no equivalent.
        assertFalse(out.contains("--kill-on-exit"))
        assertFalse(out.contains("--sysvipc"))
        assertFalse(out.contains("-L"))
        assertTrue(out.contains("--link2symlink"))
        assertTrue(out.contains("-0"))
        val rootAt = out.indexOf("-r")
        assertEquals("{ROOTFS}", out[rootAt + 1])
        val cwdAt = out.indexOf("-w")
        assertEquals("/root", out[cwdAt + 1])
        assertEquals(listOf("/dev", "{ROOTFS}/var/lib/dsh-app/shm:/dev/shm"), binds(out))
        val envAt = template.indexOf("/usr/bin/env")
        assertEquals(template.drop(envAt), out.drop(out.indexOf("/usr/bin/env")))
    }

    /** No guest environment means no proot preamble: hand it back untouched. */
    @Test fun leavesALaunchWithoutAGuestEnvironmentAlone() {
        val argv = listOf("/native/libproot.so", "-0")
        assertEquals(argv, ProrootLaunch.convert(argv))
    }

    private fun binds(argv: List<String>): List<String> {
        val out = ArrayList<String>()
        var at = 0
        while (at < argv.size) {
            if (argv[at] == "-b") {
                out += argv[at + 1]
                at += 2
            } else {
                at++
            }
        }
        return out
    }
}
