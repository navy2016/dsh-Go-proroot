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
        // The stub loader is what routes exec into the guest; the vendor's examples pass it
        // explicitly rather than relying on an adaptive guess.
        assertEquals("--static-loader", out[1])
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
        assertEquals(listOf("/dev:/dev", "{ROOTFS}/var/lib/dsh-app/shm:/dev/shm"), binds(out))
        // The guest side keeps its variables but loses proot's `-i`: proroot needs the launcher's
        // environment, which is where its preloaded path hooks live, to reach the guest.
        val guestSide = out.drop(out.indexOf("/usr/bin/env"))
        assertEquals("/usr/bin/env", guestSide.first())
        assertFalse(guestSide.contains("-i"))
        assertEquals(template.drop(template.indexOf("/usr/bin/env") + 2), guestSide.drop(1))
    }

    /** No guest environment means no proot preamble: hand it back untouched. */
    @Test fun leavesALaunchWithoutAGuestEnvironmentAlone() {
        val argv = listOf("/native/libproot.so", "-0")
        assertEquals(argv, ProrootLaunch.convert(argv))
    }

    /** proroot rejects a bare path; proot's shorthand has to become host:guest. */
    @Test fun expandsBareBindsAndLeavesPairsAlone() {
        val argv = listOf(
            "/native/libproot.so", "-r", "/native/rootfs", "-b", "/sys",
            "-b", "/data/root:/root", "--bind=/apex",
            "/usr/bin/env", "-i", "/bin/sh", "-c", "true",
        )
        val out = ProrootLaunch.convert(argv)
        assertEquals(listOf("/sys:/sys", "/data/root:/root", "/apex:/apex"), binds(out))
    }

    /** Without a guest root there is nothing to rebuild: hand the launch back untouched. */
    @Test fun leavesALaunchWithoutARootAlone() {
        val argv = listOf("/native/libproot.so", "-0", "/usr/bin/env", "-i", "/bin/sh", "-c", "true")
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
