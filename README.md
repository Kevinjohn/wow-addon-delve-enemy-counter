# Delve Enemy Counter

A small World of Warcraft addon. Inside a Delve, affixes such as Nemesis
Influence keep their "Enemy groups remaining: 1 / 4" state in a mouse-over
tooltip on the tracker's widget icon. This addon paints the remaining number
in white over that icon, so it is readable at a glance.

The game counts enemy *groups*, not individual enemies: the number drops by
one when a whole pack is cleared, so four groups left is a good deal more than
four mobs. The addon shows the game's own figure and does no arithmetic of its
own.

Nothing happens outside Delves.

## Install

Copy `DelveEnemyCounter.toc` and `DelveEnemyCounter.lua` into
`World of Warcraft/_retail_/Interface/AddOns/DelveEnemyCounter/`.

## Commands

    /dec            show the current state and any groups remaining
    /dec on|off     turn the overlay on or off
    /dec debug      dump every widget frame and the text the count came from

Also in Esc > Options > AddOns > Delve Enemy Counter.

## Checking

    sh scripts/check.sh

Runs `luacheck` over the addon (config in `.luacheckrc`) and the behaviour
harness in `tests/run.lua`. Any Lua 5.1 or later interpreter works.

The same checks run as a pre-commit hook. Turn it on once per clone:

    git config core.hooksPath hooks

A commit whose checks fail is aborted; `git commit --no-verify` overrides it.

## Licence

MIT. See `LICENSE`.
