# Delve Enemy Counter

A small World of Warcraft addon. Inside a Delve, affixes such as Nemesis
Influence keep their "Enemy groups remaining: 1 / 4" state in a mouse-over
tooltip on the tracker's widget icon. This addon paints the remaining number
in white over that icon, so the count is readable at a glance.

Nothing happens outside Delves.

## Install

Copy `DelveEnemyCounter.toc` and `DelveEnemyCounter.lua` into
`World of Warcraft/_retail_/Interface/AddOns/DelveEnemyCounter/`.

## Commands

    /dec            show the current state and any count found
    /dec on|off     turn the overlay on or off
    /dec debug      dump every widget frame and the text the count came from

Also in Esc > Options > AddOns > Delve Enemy Counter.

## Checking

    luacheck *.lua

## Licence

MIT. See `LICENSE`.
