# dmgbuild settings: drag-to-Applications installer window.
# Run: dmgbuild -s dmg/settings.py -D app="Drone File Transfer.app" -D icon=... -D background=... "Drone File Transfer" out.dmg
import os

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

icon = defines.get("icon")              # volume icon (.icns)
background = defines.get("background")  # 640x400 (+@2x) tiff

window_rect = ((200, 140), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (160, 165),
    "Applications": (480, 165),
}
