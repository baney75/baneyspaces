#!/usr/bin/python3
"""A tiny GTK4 app for the hands tests: an entry, a button that counts, a check box and a label.
The window's background is blue while the count is even and red while it is odd, so a capture can
be checked for showing the latest click.
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
        css = Gtk.CssProvider()
        rules = "window.bs-even { background: rgb(0, 0, 220); } window.bs-odd { background: rgb(220, 0, 0); }"
        if hasattr(css, "load_from_string"):
            css.load_from_string(rules)
        else:
            css.load_from_data(rules, -1)
        Gtk.StyleContext.add_provider_for_display(win.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.win = win
        win.add_css_class("bs-even")
        win.present()
        GLib.timeout_add(300, self.announce)

    def announce(self):
        print("ready", os.getpid(), flush=True)
        return False

    def on_click(self, _b):
        self.count += 1
        self.label.set_label(f"count {self.count}")
        odd = self.count % 2 == 1
        self.win.remove_css_class("bs-even" if odd else "bs-odd")
        self.win.add_css_class("bs-odd" if odd else "bs-even")


if __name__ == "__main__":
    sys.exit(App().run([]))  # arguments are read above, not by GApplication
