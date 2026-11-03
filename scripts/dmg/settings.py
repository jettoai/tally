# dmgbuild settings for the Tally installer window, the first screen a download shows.
# Run through scripts/dmg/make-dmg.sh, which passes -D app=<Tally.app> -D background=<background.tiff>.
# dmgbuild executes this file with `defines` in scope and no __file__, so paths arrive as defines.
# Coordinates are Finder points from the top left of the window's content area; an icon location
# is the centre of the icon. Keep them in step with scripts/dmg/background.html.
# window_rect is the Finder window frame with its 32 pt title bar included, so 432 tall gives a
# 400 pt content area for the 660x400 background.
app = defines["app"]
background = defines["background"]

format = "UDZO"
filesystem = "HFS+"
files = [(app, "Tally.app")]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Tally.app"]

default_view = "icon-view"
window_rect = ((400, 280), (660, 432))
show_toolbar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
label_pos = "bottom"
icon_size = 128
text_size = 12
icon_locations = {"Tally.app": (170, 200), "Applications": (490, 200)}
