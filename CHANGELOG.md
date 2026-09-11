# Changelog

All notable changes to this project are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]

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
  setting -- is deliberately plain and expected to change.
- Not yet tested in a live Delve; the test harness stubs the widget API.
