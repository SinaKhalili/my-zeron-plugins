# Pixel Walker

A tiny pixel fellow in a red cap strolls across Zeron's top bar, pauses at the edges, and turns around. Inspired by the little person in Bisqwit's editor, with original pixel artwork drawn directly by Zeron's canvas.

The open chat's running subagents each add another walker with a distinct cap colour and slightly different pace. Finished, paused, stale or disconnected subagents leave; switching chats follows that chat's activity. Both harness-native subagents and Zeron child chats marked as subagents are counted. Side conversations and background shell commands are not counted.

He lets clicks pass through, adds no layout space, and makes no sounds or notifications. Walkers rest while the window is hidden or Reduce Motion is on.

In **Settings → Pixel Walker**, pause walking, change the speed or size, or turn off subagent companions. Disable the plugin to remove everyone.

The plugin uses `ui.add`, `sessions.read`, and `commands` with Python 3. A small standard-library helper samples Zeron's authenticated loopback activity feed every 2.5 seconds while the window is visible. It only requests session/chat registry snapshots, returns active subagent identifiers, and never reads transcripts or sends data to an external service. The local IPC credential is never returned or logged.
