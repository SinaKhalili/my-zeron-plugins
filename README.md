# my-zeron-plugins

some cool zeron plugins for u

Plugins for [Zeron](https://zeron.sh), one folder each. Every folder is a whole plugin: its manifest (`zeron-plugin.json`), its code (Luau, some with a small Python helper), and its own README.

## Installing one

Each plugin installs from its folder's link, for example:

```
https://github.com/SinaKhalili/my-zeron-plugins/tree/main/cad
```

The easiest way is to ask an agent in a Zeron chat: "install the plugin at https://github.com/SinaKhalili/my-zeron-plugins/tree/main/cad". Zeron checks the plugin's signature, then shows you who signed it and what it asks for. Nothing runs until you allow it in Zeron's window.

The plugins are signed with my key, so Zeron refuses a copy whose files were changed. To change one, put your own copy in Zeron's plugins folder and sign it as you: `zeron plugin sign <id>`.

## The plugins

### [Account Usage](account-usage/)

Remaining session and weekly usage for the selected coding account, in Zeron’s bottom bar.

<img src="media/account-usage.png" width="668" alt="Account Usage: the remaining usage under the message box">

- Folder: `account-usage` · version 1.1.0
- Asks for: `ui.add`, `commands`
- Needs: Python 3

### [CAD](cad/)

Parametric 3D CAD beside your chat: describe a part and the agent models it, then shape it with the mouse, sliders and sketches.

<img src="media/cad.gif" width="520" alt="CAD: a model rebuilding as its parameters change">

<img src="media/cad.png" width="520" alt="The CAD tab beside a chat">

- Folder: `cad` · version 0.1.0
- Asks for: `ui.add`, `panel.tabs`, `compose`, `tools`, `files`

### [Cosmos](cosmos/)

A deep-space look for the whole window: stars and a nebula behind everything, a ringed planet, a rocket on the message box, tonight's moon, and an orbital wallpaper for new chats.

<img src="media/cosmos.png" width="864" alt="Cosmos: stars and a nebula behind the whole window, a planet in the corner, a rocket on the message box">

<a href="media/cosmos-trailer.mp4"><img src="media/cosmos-trailer.gif" width="520" alt="The Cosmos trailer: a Saturn V counting down and leaving the message box"></a>

▶ [Watch the trailer](media/cosmos-trailer.mp4) (39 seconds, with sound). The voices are NASA's own recordings of Apollo 11.

- Folder: `cosmos` · version 1.0.0
- Asks for: `ui.add`, `ui.change`, `sessions.read`

### [Headamp](headamp/)

A tiny top-bar music player that opens a full retro Winamp deck.

<img src="media/headamp.png" width="446" alt="Headamp: the top-bar player and its Winamp deck">

- Folder: `headamp` · version 1.3.1
- Asks for: `ui.add`, `web`, `commands`
- Needs: Python 3, to read a folder of music

### [Pixel Walker](pixel-walker/)

A tiny pixel fellow, joined by a colour-coded walker for each running subagent of the open chat.

<img src="media/pixel-walker.gif" width="900" alt="Pixel Walker: a pixel fellow walking along the top bar">

- Folder: `pixel-walker` · version 1.1.0
- Asks for: `ui.add`, `sessions.read`, `commands`
- Needs: Python 3

### [Plugin Manager](plugin-manager/)

A Plugins row in the sidebar that opens Settings → Plugins in one click.

<img src="media/plugin-manager.png" width="327" alt="Plugin Manager: the Plugins row in the sidebar">

- Folder: `plugin-manager` · version 0.1.0
- Asks for: `pages.add`, `navigate`

### [VPS Stats](vps-stats/)

Live CPU, RAM, disk, load, and uptime for your VPS.

- Folder: `vps-stats` · version 1.1.0
- Asks for: `ui.add`, `pages.add`, `commands`
- Needs: `ssh` access to the server, with Python 3 on it

## License

MIT, see [LICENSE](LICENSE). Headamp bundles [Webamp](https://github.com/captbaritone/webamp), also MIT; its license is in `headamp/WEBAMP-LICENSE.txt`.
