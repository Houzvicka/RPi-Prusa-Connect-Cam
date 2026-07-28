# Project Goal

This project extends the Prusa Connect Raspberry Pi Camera project while remaining fully backward compatible.

The long-term goals are:

- improve USB camera support
- implement autofocus support
- add a configuration wizard
- support camera capabilities detection
- support configurable resolution, FPS and image controls
- keep compatibility with Raspberry Pi Camera modules

# Development Rules

- Prefer small atomic commits.
- Never break existing functionality.
- Preserve backward compatibility whenever possible.
- Avoid code duplication.
- Prefer reusable helper functions over copy/paste.
- All new configuration options must be stored in prusa_cam.conf.
- Detect camera capabilities instead of assuming support.
- Missing camera features must never terminate the application; log a warning and continue.
- Bash code should remain POSIX-compatible where practical.
- Keep scripts readable and well commented.

# Commit Strategy

Recommended order:

1. Stream server refactor
2. Autofocus framework
3. Configuration wizard
4. Resolution and FPS support
5. Image controls
6. Documentation and cleanup
