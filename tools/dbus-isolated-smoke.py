#!/usr/bin/env python3
"""Run the existing smoke suite on a private bus with fake sysfs and Polkit.

Requires python-gobject, dbus-daemon, busctl, and unprivileged user namespaces:
    unshare --user --map-root-user python3 tools/dbus-isolated-smoke.py
No host services or real sysfs files are changed.
"""

import os
import subprocess
import tempfile
import threading
from pathlib import Path

# PyGObject creates these modules at runtime from installed introspection data.
from gi.repository import Gio, GLib  # pyright: ignore[reportAttributeAccessIssue]

ROOT = Path(__file__).resolve().parent.parent
NAME = "org.freedesktop.UPower.PowerProfiles"
OBJECT = "/org/freedesktop/UPower/PowerProfiles"
POLKIT = "org.freedesktop.PolicyKit1"
XML = """<node><interface name="org.freedesktop.PolicyKit1.Authority">
<method name="CheckAuthorization">
<arg type="(sa{sv})" direction="in"/><arg type="s" direction="in"/>
<arg type="a{ss}" direction="in"/><arg type="u" direction="in"/>
<arg type="s" direction="in"/><arg type="(bba{ss})" direction="out"/>
</method></interface></node>"""


def main():
    assert os.geteuid() == 0, "Run inside unshare --user --map-root-user"
    bus = subprocess.Popen(
        ["dbus-daemon", "--session", "--nofork", "--print-address=1"],
        stdout=subprocess.PIPE,
        text=True,
    )
    daemon = None
    loop = GLib.MainLoop()
    thread = None
    try:
        assert bus.stdout is not None
        os.environ["DBUS_SYSTEM_BUS_ADDRESS"] = bus.stdout.readline().strip()
        assert os.environ["DBUS_SYSTEM_BUS_ADDRESS"], "Private bus failed"
        connection = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        connection.call_sync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "RequestName",
            GLib.Variant("(su)", (POLKIT, 0)),
            None,
            Gio.DBusCallFlags.NONE,
            5000,
            None,
        )
        authorizations = []

        def authorize(conn, sender, path, interface, method, parameters, invocation):
            authorizations.append(parameters.unpack()[1])
            invocation.return_value(GLib.Variant("((bba{ss}))", ((True, False, {}),)))

        connection.register_object_with_closures2(
            "/org/freedesktop/PolicyKit1/Authority",
            Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0],
            authorize,
            None,
            None,
        )
        thread = threading.Thread(target=loop.run)
        thread.start()
        ready = threading.Event()
        Gio.bus_watch_name_on_connection(
            connection,
            NAME,
            Gio.BusNameWatcherFlags.NONE,
            lambda *args: ready.set(),
            None,
        )
        with tempfile.TemporaryDirectory(prefix="ppd-dbus-smoke-") as tree:
            profile = Path(tree) / "platform_profile"
            profile.write_text("balanced\n")
            os.environ["PLATFORM_PROFILE_PATH"] = str(profile)
            daemon = subprocess.Popen(
                [
                    str(ROOT / "zig-out/lib/platform-profile-daemon"),
                    "--platform-profile",
                    str(profile),
                ]
            )
            assert ready.wait(5), "Daemon failed to acquire private bus name"
            subprocess.run(
                ["busctl", "--system", "status", NAME],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            subprocess.run(["bash", str(ROOT / "tools/dbus-smoke.sh")], check=True)
            assert authorizations == ["net.hadess.PowerProfiles.switch-profile"] * 4, (
                authorizations
            )

            def set_profile(value):
                subprocess.run(
                    [
                        "busctl",
                        "--system",
                        "set-property",
                        NAME,
                        OBJECT,
                        NAME,
                        "ActiveProfile",
                        "s",
                        value,
                    ],
                    check=True,
                )

            before = profile.stat().st_mtime_ns
            set_profile("balanced")
            assert profile.stat().st_mtime_ns == before, "Same profile caused a write"
            profile.write_text("custom\n")
            set_profile("balanced")
            assert profile.read_text() == "balanced\n", (
                "Explicit request failed to converge"
            )
            print(
                "Isolated D-Bus smoke passed: invalid requests bypass Polkit, same-profile no-write, custom convergence."
            )
    finally:
        if daemon is not None:
            daemon.terminate()
            daemon.wait(timeout=5)
        loop.quit()
        if thread is not None:
            thread.join(timeout=5)
        bus.terminate()
        bus.wait(timeout=5)


if __name__ == "__main__":
    main()
