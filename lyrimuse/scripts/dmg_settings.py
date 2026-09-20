import os

application = os.environ["LYRIMUSE_DMG_APP"]
_app_name = os.path.basename(application)

icon = os.path.join(application, "Contents/Resources/AppIcon.icns")

filesystem = "HFS+"
format = "UDZO"

volume_name = os.environ["LYRIMUSE_DMG_VOLNAME"]

files = [application]
symlinks = {"Applications": "/Applications"}

badge_icon = None
background = os.environ["LYRIMUSE_DMG_BACKGROUND"]

window_rect = ((200, 180), (660, 400))
icon_size = 128

icon_locations = {
    _app_name: (180, 170),
    "Applications": (480, 170),
}

default_view = "icon-view"
show_icon_preview = False

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 14
