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
        # TEST_APP_ID gives the window class (Wayland app id); TEST_APP_SECOND_TITLE opens a second
        # window in the same process, as an emulator opens its toolbar or extended controls.
        super().__init__(application_id=os.environ.get("TEST_APP_ID", "dev.baneyspaces.TestApp"), flags=Gio.ApplicationFlags.DEFAULT_FLAGS if unique else Gio.ApplicationFlags.NON_UNIQUE)
        self.count = 0

    def do_activate(self):
        late = os.environ.get("TEST_APP_LATE_TITLE")  # opens untitled, gets this title 0.8 s later
        win = Gtk.ApplicationWindow(application=self, title="" if late else os.environ.get("TEST_APP_TITLE", "BaneySpaces Test App"))
        if late:
            GLib.timeout_add(800, lambda: (win.set_title(late), False)[1])
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
        second = os.environ.get("TEST_APP_SECOND_TITLE")
        if second:
            GLib.timeout_add(400, lambda: (Gtk.ApplicationWindow(application=self, title=second, default_width=240, default_height=120).present(), False)[1])
        GLib.timeout_add(900 if second else 300, self.announce)

    def announce(self):
        print("ready", os.getpid(), flush=True)
        return False

    def on_click(self, _b):
        self.count += 1
        self.label.set_label(f"count {self.count}")


if __name__ == "__main__":
    if os.environ.get("TEST_APP_ID"):
        GLib.set_prgname(os.environ["TEST_APP_ID"])  # GTK on Wayland takes the window class from here
    sys.exit(App().run([]))  # arguments are read above, not by GApplication
