local wezterm = require 'wezterm'
local mux = wezterm.mux
local config = wezterm.config_builder()

-- Non-native fullscreen fills the chosen monitor without creating a separate macOS Space,
-- which is what makes pinning the cockpit to a specific display reliable.
config.native_macos_fullscreen_mode = false

local TARGET = 'LG SDQHD'

wezterm.on('gui-startup', function()
  local screens = wezterm.gui.screens()
  local target = screens.by_name[TARGET] or screens.active or screens.main
  local _, _, window = mux.spawn_window { args = { os.getenv('HOME') .. '/.local/bin/cockpit' } }
  local gui = window:gui_window()
  gui:set_position(target.x, target.y)
  gui:toggle_fullscreen()
end)

return config
