#!/usr/bin/env python3
"""Writes demo projects and conversations into an Apelin data folder."""
import json, os, sys, uuid, datetime

root = sys.argv[1]  # .../Documents/wiki.qaq.apelin
REF = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
IDS = {}
NOW = datetime.datetime.now(datetime.timezone.utc)


def ts(dt):
    return (dt - REF).total_seconds()


def project(folder, kind, display, pid):
    d = os.path.join(root, "Projects", folder)
    os.makedirs(os.path.join(d, "Sources"), exist_ok=True)
    m = {"schemaVersion": 1, "projectID": pid, "kind": kind, "displayName": display}
    json.dump(m, open(os.path.join(d, "apelin-project.json"), "w"), indent=2)


class Chat:
    def __init__(self, title, project, minutes_ago, pinned=False):
        self.id = str(uuid.uuid4()).upper()
        self.title, self.project, self.pinned = title, project, pinned
        self.t = NOW - datetime.timedelta(minutes=minutes_ago)
        self.updated = self.t
        self.events, self.seq, self.calls = [], 0, 0

    def ev(self, kind, payload=None, dt=1.0):
        self.t += datetime.timedelta(seconds=dt)
        self.seq += 1
        e = {"seq": self.seq, "kind": kind, "time": ts(self.t)}
        if payload is not None:
            e["payload"] = payload
        self.events.append(e)

    def user(self, text):
        self.ev("prompt", {"text": text, "id": str(uuid.uuid4()).upper()}, 4)

    def think(self, text, dt=4):
        self.ev("messageStarted", None, 0.3)
        self.ev("thinking", {"text": text}, dt)

    def tool(self, name, args, output, reason, dt=1.5):
        self.calls += 1
        cid = f"call_{self.calls:02d}"
        self.ev("toolCall", {"id": cid, "tool": name, "arguments": json.dumps(args), "reason": reason}, 0.5)
        self.ev("toolResult", {"id": cid, "tool": name, "isError": False, "output": output}, dt)

    def say(self, text, tokens=None):
        self.ev("messageStarted", None, 0.3)
        self.ev("text", {"text": text}, 2)
        self.ev("message", {"text": text}, 0.2)
        if tokens:
            self.ev("received", {"tokens": tokens}, 0)

    def finish(self):
        self.ev("finished", {"reason": "completed"}, 0.2)

    def write(self):
        rec = {
            "summary": {"id": self.id, "title": self.title, "updated": ts(self.updated),
                        "isPinned": self.pinned, "isWorking": False, "isNamedByReader": True,
                        **({"projectName": self.project} if self.project else {})},
            "draft": {"id": str(uuid.uuid4()).upper(), "text": "", "attachments": []},
            "events": self.events,
        }
        d = os.path.join(root, "Chats")
        os.makedirs(d, exist_ok=True)
        json.dump(rec, open(os.path.join(d, self.id + ".json"), "w"), ensure_ascii=False)
        IDS[self.title] = (self.id, self.project)
        return self.id


project("DockGlass", "tweak", "Dock Glass", "8C1F4A6E-2B71-4C1E-9E1B-5D0A2E7C3F10")
project("Pulse", "app", "Pulse", "1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F")
project("batt", "cli", "batt", "2E3F4051-6B7C-4D8E-9FA0-1B2C3D4E5F60")
project("LockTweaks", "preferences", "Lock Screen Tweaks", "3F405162-7C8D-4E9F-A0B1-2C3D4E5F6071")

# --- 1. Tweak chat (the hero) -------------------------------------------------
c = Chat("Frosted Dock", "DockGlass", 3, pinned=True)
c.user("Make the dock frosted glass, and give app icons a little bounce when they launch.")
c.think("The dock background is SBDockView's backgroundView. I'll swap it for a UIVisualEffectView, then hook SBIconView's launch to add a spring animation.", 6)
c.tool("file_read", {"path": "Sources/Tweak.m"}, "1\t// From Apelin's tweak template.\n2\t#import <UIKit/UIKit.h>\n...", "Read the template's hook")
c.tool("file_edit", {"path": "Sources/Tweak.m"}, "Patched Sources/Tweak.m +38 -4", "Add the dock and launch hooks")
c.tool("apelin_project_build", {}, "{\"state\":\"succeeded\",\"bootstrap\":\"roothide\"}", "Build the tweak", 9)
c.tool("apelin_package_install", {}, "Installed local.apelin.dockglass 0.0.2", "Install the package", 4)
c.tool("apelin_package_confirm_loaded", {"respring": True}, "{\"loaded\":true}", "Respring and check it loaded", 12)
c.say("""Done — built, installed and **confirmed loaded** in SpringBoard.

```objc
static void Dock(id self, SEL s) {
  Orig_layout(self, s);
  id blur = [UIBlurEffect
    effectWithStyle:Thin];
  [self setBackgroundView:
    [[UIVisualEffectView alloc]
      initWithEffect:blur]];
}
```

- **Dock:** `SBDockView` gets a thin material blur
- **Launch:** a 0.35 s spring on `SBIconView`""", 1284)
c.finish()
hero = c.write()

# --- 2. Toolchain chat ------------------------------------------------------
c = Chat("Choosing a Toolchain", None, 42)
c.user("Which toolchain should I set up on this iPhone? I want Swift too.")
c.think("Reading the catalog and this device's CPU features.", 3)
c.tool("apelin_toolchain_list", {}, "...", "See what this device can run")
c.say("""Your iPhone 15 Pro runs every release Apelin sets up. For Swift, pick **CLT 27.0**:

| Release | Swift | Newest SDK | Size |
| --- | --- | --- | --- |
| 27.0 | 6.4 | iOS 27.1 | 1.1 GB |
| 15.3 | 5.10 | iOS 17.4 | 0.9 GB |
| 15.0 | 5.9 | iOS 17.0 | 0.9 GB |
| 14.2 | 5.7 | iOS 16.2 | 0.8 GB |

27.0 also self-tests Swift async and macros. Want me to set it up? It downloads straight from Apple — no Xcode or Apple ID.""", 412)
c.finish()
c.write()

# --- 3. CLI chat ------------------------------------------------------------
c = Chat("Battery Health", "batt", 95)
c.user("Write a command-line tool that prints battery health and cycle count.")
c.think("IOKit's AppleSmartBattery service has CycleCount, DesignCapacity and NominalChargeCapacity.", 5)
c.tool("file_write", {"path": "Sources/main.c"}, "Wrote Sources/main.c +41 -0", "Write the tool")
c.tool("apelin_project_build", {}, "{\"state\":\"succeeded\"}", "Build it", 6)
c.tool("shell_run", {"argv": ["batt"]}, "Health   94%\nCycles   312\nTemp     31.2 °C", "Run it once")
c.say("""`batt` reads IOKit's `AppleSmartBattery` and prints:

```
Health   94%
Cycles   312
Temp     31.2 °C
```

Run it from the terminal tab, or pass `--json` for scripts.""", 655)
c.finish()
c.write()

# --- 4. Pulse app chat ------------------------------------------------------
c = Chat("Heart Rate Chart", "Pulse", 60 * 22)
c.user("Add a chart of the last 24 hours to the main screen.")
c.think("Swift Charts is available from iOS 16, the project's deployment target.", 4)
c.tool("file_edit", {"path": "Sources/ContentView.swift"}, "Patched +27 -3", "Add the chart view")
c.tool("apelin_project_build", {}, "{\"state\":\"succeeded\"}", "Build the app", 14)
c.say("""Added a `LineMark` chart above the list, with a gradient area underneath.

```swift
Chart(samples) { s in
  AreaMark(
    x: .value("Time", s.date),
    y: .value("BPM", s.bpm))
  .foregroundStyle(.red.gradient)
  LineMark(
    x: .value("Time", s.date),
    y: .value("BPM", s.bpm))
}
```""", 870)
c.finish()
c.write()

# --- 5. Crash chat ----------------------------------------------------------
c = Chat("Why Did SpringBoard Crash?", "DockGlass", 48)
c.user("SpringBoard crashed right after I installed the last build. What happened?")
c.think("Open the newest SpringBoard report and symbolicate it against this project's dSYMs.", 4)
c.tool("apelin_crash_list", {}, "SpringBoard-2026-10-26-0912.ips", "Find the report")
c.tool("apelin_crash_symbolicate", {"id": "SpringBoard-2026-10-26-0912.ips"}, "...", "Symbolicate it", 3)
c.say("""It's ours: an `EXC_BAD_ACCESS` in the dock hook, build `0.0.1`.

```
0  DockGlass.dylib  Dock + 48
     Sources/Tweak.m:31
1  SpringBoard      -[SBDockView layoutSubviews]
2  UIKitCore        -[UIView layoutSublayers]
```

`backgroundView` was read before the original ran, so it was still `nil`. The build after that one already calls the original first — install **0.0.2** and it's fixed.""", 733)
c.finish()
c.write()

# --- 6. Publishing chat -------------------------------------------------------
c = Chat("Publish to My Repository", "DockGlass", 130)
c.user("Build a release for both bootstraps and publish it to my package repository.")
c.think("Release builds for roothide and rootless, then publish both debs.", 3)
c.tool("apelin_project_build", {"configuration": "release", "bootstrap": "roothide"}, "{}", "Release build for roothide", 8)
c.tool("apelin_project_build", {"configuration": "release", "bootstrap": "rootless"}, "{}", "Release build for rootless", 8)
c.tool("git_push", {}, "main -> main", "Push the packages", 3)
c.say("""Published **Dock Glass 1.0** to `lakr233.github.io/packages`:

- `dockglass_1.0_iphoneos-arm64e.deb` — roothide
- `dockglass_1.0_iphoneos-arm64.deb` — rootless

GitHub Pages rebuilds the index in about a minute; Irisin picks it up on the next refresh.""", 521)
c.finish()
c.write()

# --- More sidebar rows ------------------------------------------------------
for title, proj, ago in [
    ("Hide the home bar on the lock screen", "LockTweaks", 60 * 26),
    ("Translucent folders", "DockGlass", 60 * 26),
    ("Haptic on long press", "DockGlass", 200),
    ("Respect Reduce Motion", "DockGlass", 60 * 27),
    ("A Settings pane for the blur", "DockGlass", 60 * 50),
    ("Port the Theos tweak", "DockGlass", 60 * 75),
    ("Respring without losing state", None, 60 * 80),
    ("Sign in with GitHub", None, 60 * 100),
]:
    c = Chat(title, proj, ago)
    c.user(title)
    c.say("Sure — here's how.", 40)
    c.finish()
    c.write()

json.dump(IDS, open(sys.argv[2], "w"), indent=1)
