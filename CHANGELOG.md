# Changelog

All notable changes to this project are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-12

### Changed
- The enemy groups remaining now reads as part of Blizzard's own Delve tracker:
  a skull and a number in the tracker header, sitting beside the lives
  remaining in the same row, the same font, the same colour. No more white text
  over the affix icon.
- The skull is the game's own marker for enemies, so the row says what it means
  at a glance: skull and a number for the groups left, heart and a number for
  the lives left.
- Under the hood it is one more frame in the header's own currency container,
  placed by Blizzard's layout rather than anchored over the top of it. Widgets
  without that row keep the old overlay.

### Added
- `/dec icon <name>`, `/dec size <n>`, `/dec gap <n>`, `/dec y <n>` and
  `/dec x <n>`, all taking effect on the spot with no reload, plus
  `/dec reset`. Icons: `skull`, `swords`, `cross`, `heart`
  (copies the lives icon) and `affix` (the reporting affix's own spell icon);
  any texture path or atlas name is accepted too. Size is a fraction of the
  lives icon beside it, 0.3 to 2; gap is the pixels between the icon and the
  count, 0 to 20; y lifts the icon without moving the count, -10 to 10; x
  shifts the whole thing sideways, -40 to 40. All are saved.
- Hovering the count shows the text it was read from.

### Notes
- Checked in a live Delve; the placement and sizes are what came out of that.

## [0.1.0] - 2026-09-11

### Added
- First version. Inside a Delve, paints the Nemesis Influence "enemy groups
  remaining" count in white over the Delve tracker's affix icon and leaves it
  there. The game offers that number through a mouse-over only, which puts it
  out of reach without a mouse; this makes it readable with no pointer at all.
  It is the game's own figure, counting enemy groups rather than individual
  enemies. Nothing happens outside Delves.
- The count is read from whichever source the client has: the widget manager's
  own data for the widget, an affix spell's live description (painted on that
  spell's own icon), or a tooltip kept on the widget frame or one of its
  children. It follows the live value on every widget update, and the number is
  taken down when an affix stops reporting one.
- `/dec` (or `/delveenemycounter`): `on`, `off`, `status` and `debug`, the last
  dumping every widget frame and the text each count came from.
- A tick box in Esc > Options > AddOns > Delve Enemy Counter, changing the
  overlay live and agreeing with `/dec` in both directions. A client without
  the Settings API loads quietly and keeps the slash command.
- Behaviour test harness in `tests/run.lua`, run with the luacheck pass by
  `sh scripts/check.sh`.
- Pre-commit hook in `hooks/pre-commit` running those same checks, active once
  per clone with `git config core.hooksPath hooks`.

### Notes
- Separated out of Mislaid Curiosity TomTom, where this was one option among
  many, into an addon that does only this.
- The overlay's look -- white text centred on the icon, no size or colour
  setting -- is deliberately plain and expected to change. (Changed in 0.2.0.)
- Not yet tested in a live Delve; the test harness stubs the widget API.
