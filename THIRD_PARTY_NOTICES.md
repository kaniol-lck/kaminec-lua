# Third-party notices

## dkjson

`src/json.lua` is David Kolf's dkjson (version 2.5), vendored as a single file.

- Copyright (c) 2010-2014 David Heiko Kolf
- License: MIT
- Upstream: https://github.com/LuaDist/dkjson

The file retains its original copyright and license header. It is vendored so
that the launcher runs without LuaRocks or a build step.

## External runtimes

This project does not distribute Lua, curl, or Java. Users install them
separately:

- Lua 5.4 — MIT
- curl — curl license
- Java / OpenJDK — GPLv2 with Classpath Exception (distribution-dependent)

## Inspiration / prior art

- Kaminec (C++/Qt original launcher): https://github.com/kaniol-lck/Kaminec
- KL_Launcher (Lua reference): https://github.com/kaniol-lck/KL_Launcher

Minecraft is a trademark of Mojang Studios. This project is not affiliated
with Mojang, Microsoft, or the official Minecraft launcher.
