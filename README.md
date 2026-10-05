# Xenia Guy

GUI manager for Xenia Canary, in Autoit.

## Features

- Scans games, shows posters, names, serials, versions, compatibility ratings, and disk space.
- Boot with custom or global config. Right-click for patches, custom config, and desktop shortcuts.
- Manage game patches (enable/disable, save choices).
- Edit global Xenia settings (xenia-canary.config.toml) with search and descriptions.
- Update compatibility database, patches, and Xenia Canary.

## Screenshots

Main window:

![Main](Examples\XeniaGuy1.jpg)

Global settings:

![Settings](Examples\XeniaGuy2.jpg)

Game patches:

![Patches](Examples\XeniaGuy3.jpg)

## Requirements

- xenia_canary.exe in the same folder.
- Compiled release (.exe) runs without AutoIt.
- To build from source: AutoIt 3.3.18.0 or later from https://www.autoitscript.com/site/autoit/downloads/

Place games in the Games folder (or set a custom path). Data is stored in XeniaGuy/.
