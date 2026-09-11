# Delve Enemy Counter

**Shows how many enemy groups are left in your Delve, without the mouse-over.**

When a Delve rolls Nemesis Influence, you have to clear a set number of enemy
groups. The game tracks it — but only tells you if you stop and hover the affix
icon. Mid-pull, that means you don't know whether you're one group from done or
four.

This paints the number straight onto the icon. Glance, don't hover.

Nothing happens outside Delves. The number is the game's own; it counts groups,
not individual mobs.

## Install

Copy `DelveEnemyCounter.toc` and `DelveEnemyCounter.lua` into
`World of Warcraft/_retail_/Interface/AddOns/DelveEnemyCounter/`.

Turn it off any time: Esc > Options > AddOns > Delve Enemy Counter, or `/dec off`.

## Commands

    /dec            what it's doing, and the groups remaining
    /dec on|off     turn the number on or off
    /dec debug      what the addon can see (for bug reports)

## Developing

    sh scripts/check.sh              # luacheck + tests/run.lua
    git config core.hooksPath hooks  # once per clone: run those before each commit

## Licence

MIT. See `LICENSE`.
