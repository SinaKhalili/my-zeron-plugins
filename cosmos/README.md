# Cosmos

A deep-space look for Zeron's whole window.

- **The sky**: stars, a nebula in your accent's hues and a ringed planet behind the sidebar and title bar, and a fainter sky behind the conversation. Drawn once on the GPU (`space.luau`, WGSL), so it costs nothing at rest.
- **Twinkles and shooting stars**: compositor-only animation, paused while the window is hidden or Reduce Motion is on.
- **The rocket**: a small 3D model standing on the message box, drawn by `ui.scene3d`; it lights its engines and climbs while the chat's agent works, and comes back down when it's done. Pick which in Settings → Plugins → Cosmos → Which rocket: a Saturn V, the Space Shuttle, a Falcon 9 (its legs fold as it leaves), Starship or a Soyuz, each stylized from the real vehicle's dimensions. It draws no frames while it stands.
- **Tonight's moon**: the real lunar phase after a chat's title (`moon.luau`).
- **Orbit wallpaper**: the view from low orbit behind a new chat. Turn on "Use as wallpaper" in Settings → Plugins → Cosmos.

The colours are the companion **Cosmos** theme (Settings → Themes), in dark and light. A plugin draws; a theme colours.

Files: `init.luau` (placements), `space.luau` (shaders), `art.luau` (SVG drawings), `ship.luau` (the rocket's scene: lights, exhaust, motion), `fleet.luau` (the rockets' models), `solids.luau` (the shapes they're built from), `moon.luau` (phase maths), `locales/en.json`.

Permissions: `ui.add` (placing the sky, rocket and moon), `ui.change` (the new-chat background), `sessions.read` (the session's status, for the rocket).
