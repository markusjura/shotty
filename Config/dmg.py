# dmgbuild settings for Shotty's disk image: the app beside an Applications shortcut, with an arrow between.
# Scripts/package.sh runs dmgbuild from the repository root with -D app=<path to Shotty.app>.
# Icon positions are icon centers in window points; Scripts/GenerateDMGBackground.swift draws the arrow to match.
import os.path

app = defines["app"]
name = os.path.basename(app)

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

background = "Config/DMGBackground.png"
window_rect = ((200, 200), (560, 340))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {name: (140, 150), "Applications": (420, 150)}
hide_extensions = [name]
