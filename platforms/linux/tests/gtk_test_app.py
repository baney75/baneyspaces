#!/usr/bin/python3
"""A tiny GTK4 app for the hands tests: an entry, a button that counts, a check box and a label.
Run with /usr/bin/python3 (needs python-gobject, GTK 4). Prints "ready <pid>" when mapped."""
import os
import sys

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402


class App(Gtk.Application):
    def __init__(self):
        # By default every run is its own process (NON_UNIQUE). With --unique it is a normal
        # single-instance GApplication: a second run forwards to the first and exits.
        unique = "--unique" in sys.argv
        super().__init__(application_id="dev.baneyspaces.TestApp", flags=Gio.ApplicationFlags.DEFAULT_FLAGS if unique else Gio.ApplicationFlags.NON_UNIQUE)
        self.count = 0

    def do_activate(self):
        win = Gtk.ApplicationWindow(application=self, title=os.environ.get("TEST_APP_TITLE", "BaneySpaces Test App"))
        win.set_default_size(420, 240)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        self.entry = Gtk.Entry(placeholder_text="name")
        self.entry.update_property([Gtk.AccessibleProperty.LABEL], ["Name field"])
        self.button = Gtk.Button(label="Count")
        self.label = Gtk.Label(label="count 0")
        self.check = Gtk.ToggleButton(label="Enabled")
        self.button.connect("clicked", self.on_click)
        for w in (self.entry, self.button, self.label, self.check):
            box.append(w)
        win.set_child(box)
        win.present()
        GLib.timeout_add(300, self.announce)

    def announce(self):
        print("ready", os.getpid(), flush=True)
        return False

    def on_click(self, _b):
        self.count += 1
        self.label.set_label(f"count {self.count}")


if __name__ == "__main__":
    sys.exit(App().run([]))  # arguments are read above, not by GApplication
