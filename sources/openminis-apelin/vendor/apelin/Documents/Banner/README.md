# The banner

`Documents/screenshots.jpg` is the banner the README shows and every
package manager shows above Apelin's depiction (`Documents/Site/depiction.json`
▸ `headerImage`), as Fila's is. It is made from a Figma template, never drawn
by hand:

- `Template.fig` — the layout: Apptisan's FlowDown banner, untouched but for
  its slots' names (`Screenshot 1` … `Screenshot 6`, `Icon`; a slot can
  appear more than once) and the Icon slot's corners, 22.37 % to match the
  iOS icon mask.
- `Banner.fig` — the template with Apelin's screenshots and icon in its
  slots, as the last run left it. Open it in Figma to look at it or export
  it there.
- `demo-data.py` — the projects and conversations the screenshots show,
  written into the app's data folder. Nothing in them is a real session.
- `make-banner.sh` — the whole run:
  1. builds the app for the iOS Simulator into
     `/private/tmp/apelin-banner-deriveddata` (a screenshot build only:
     Apelin ships no simulator build, and nothing that needs apelind works
     there);
  2. installs it on an existing iPhone simulator (`SIMULATOR`, default
     "iPhone 18 Pro"), light mode, the status bar at 9:41;
  3. writes the demo data, then opens each conversation in `CHATS` and takes
     a screenshot of it without the display's rounded mask;
  4. exports the icon from `Documents/Icon/AppIcon.icon` with Icon Composer's
     `ictool`;
  5. fills the template (`Tool/fill-slots.mjs`), renders its frame at 2x
     (`Tool/render.mjs`, `Tool/snapshot.swift`), keeps it in
     `build/Banner/banner@2x.png` and scales it down to the frame's size as
     `Documents/screenshots.jpg` (JPEG, quality 85: under 1 MB), and writes
     `Banner.fig`, its screenshots JPEG too;
  6. uninstalls the app and shuts the simulator down if it booted it.

  Working files go to `build/Banner/`.

`Tool/` is a pnpm package (`pnpm install` there; the script does it).
`fig.mjs` reads and writes `.fig` canvases: `fig-kiwi`, a version, then the
kiwi schema and the message, each deflated. `render.mjs` draws what the frame
holds in this template (rectangles with a solid or image fill, transform,
corner radius, drop shadows, an inside stroke) and stops short of the rest.
Figma's corner smoothing has no CSS equivalent, so the render's corners are
plain arcs; Figma draws `Banner.fig` with its own.

```sh
Documents/Banner/make-banner.sh
SIMULATOR="iPhone 17" Documents/Banner/make-banner.sh
```

Change what the screenshots say in `demo-data.py`, and which conversation
goes in which slot in `CHATS`: `Screenshot 1` is the largest.
