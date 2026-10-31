# dmgbuild settings for build/BaneySpaces.dmg; scripts/package.sh passes `app` and `background`.
# Coordinates are points in the window, from its top left: the window is 640x400, and the
# background (scripts/make-dmg-background.swift) draws its arrow between the two icon centers.
import os.path

app = defines["app"]  # noqa: F821  (dmgbuild provides `defines`)
name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_locations = {name: (170, 190), "Applications": (470, 190)}
