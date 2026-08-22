# PerfectGrabber RootHide source rebuild

This project reimplements the original package behavior while preserving its preference domain and keys.

The original binaries read and wrote this invalid RootHide path directly:

`/var/jb/var/mobile/Library/Preferences/com.netskao.perfectgrabber.plist`

The rebuild uses `CFPreferences` with domain `com.netskao.perfectgrabber` and posts the original Darwin notification `com.netskao.perfectgrabber.settingschanged`.

Build from Windows:

```powershell
.\build.ps1
```

Build output is organized by version under the project release directories:

```text
../测试版/Ntonia-PreferenceLoader-bate<build-number>_hide64e/
  Ntonia-PreferenceLoader.deb
  Ntonia-PreferenceLoader-bate<build-number>_hide64e.zip
  SHA256.txt
  更新日志.txt
```

Keep test builds in `测试版`. Move a complete version directory to `正式版` only after
the user has confirmed the package on a real device.

Run `archive-history.ps1` to collect historical loose DEB files into the same release
layout. Hash-identical copies are deduplicated; differing builds with the same version
are preserved under that version's `历史构建` directory.
