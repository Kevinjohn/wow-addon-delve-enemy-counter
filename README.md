# Delve Enemy Counter

**Puts the enemy groups remaining on screen, where anyone can read it.**

A Delve with Nemesis Influence gives you a quota of enemy groups to clear. The
game tracks it, then shows it only to a mouse pointer parked on the affix icon.

If you don't use a mouse, that count doesn't exist. Not slower to reach —
unavailable. Keyboard, controller, or any setup that can't rest a pointer on
one small icon on demand: the game is keeping progress you need to play well
behind an input method you don't have. Hover is a fine way to offer detail. It
is not a fine way to be the only way.

This puts the number in the tracker's own header, alongside the lives
remaining, and leaves it there. No pointer, no hover, no interaction. It is
drawn the way the game draws that row, so it reads as part of the UI rather
than on top of it. Mouse users get it at a glance mid-pull too.

Nothing happens outside Delves. The number is the game's own; it counts groups,
not individual mobs.

## Install

From [CurseForge](https://www.curseforge.com/wow/addons/delve-enemy-counter), or
copy `DelveEnemyCounter.toc` and `DelveEnemyCounter.lua` into
`World of Warcraft/_retail_/Interface/AddOns/DelveEnemyCounter/`.

Turn it off any time: Esc > Options > AddOns > Delve Enemy Counter, or `/dec off`.

## Commands

    /dec              what it's doing, and the groups remaining
    /dec on|off       turn the number on or off
    /dec icon <name>  skull, swords, cross, heart, affix, or a texture path
    /dec size <n>     icon size, 1 matches the lives icon beside it
    /dec gap <n>      pixels between the icon and the count
    /dec y <n>        lift the icon, to sit level with the count
    /dec reset        icon and size back to the defaults
    /dec debug        what the addon can see (for bug reports)

The icon, size, gap and lift change on the spot, no reload, so they can be judged in a
real Delve rather than guessed at.

## Developing

    sh scripts/check.sh              # luacheck + tests/run.lua
    git config core.hooksPath hooks  # once per clone: run those before each commit

## Licence

MIT. See `LICENSE`.
