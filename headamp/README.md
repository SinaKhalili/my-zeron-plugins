# Headamp

A local music player in Zeron’s top bar. The track display opens a standalone Winamp-style deck powered by Webamp 2.3.1, without a surrounding panel. The player sits clear of Zeron’s own top-bar icons. Previous, play/pause and next controls remain in the top bar. The current track’s embedded album art appears beside its title; files without artwork use a small record icon. Cover thumbnails are cached and stay on this device.

Each time Zeron starts, Headamp lists the music in your folders: `~/Music` unless you name others in Settings → Headamp → Music folders (several, separated by commas; subfolders are included). These tracks play from where they are: a track is read as it is about to play, the next one is read ahead, and nothing is copied. Headamp → Rescan music folders lists them again. Add other audio files with the classic deck’s Add/Eject controls, or use Headamp → Add music files / Add music folder in the menu bar. Click outside the deck or press Escape to fold it away. It never plays automatically on startup. The playlist, equalizer, volume, shuffle, and repeat are available in the deck. Closing the deck keeps playback going. Imported files are stored in this plugin’s private browser library when local browser storage is available.

Headamp bundles its player code and plays files on this device. It uses no music service, external server or tracking, and its page blocks network connections. To list and read the folders it runs `python3` with a bundled script (`library.luau`) that only reads audio files inside those folders; each run ends as soon as it has answered. The top-bar switch is in Settings → Headamp. No notifications.

Permissions: `ui.add` for the top-bar controls, `web` for the embedded audio player, and `commands` (`python3`) to list and read your music folders. Zeron asks you to allow these once.

Webamp: https://github.com/captbaritone/webamp · MIT license, included in WEBAMP-LICENSE.txt.
