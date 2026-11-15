extension BuiltInSkills {
    static let packageDependencies = SkillDocument(
        name: "apelin-package-dependencies",
        description: "Getting a package installed: your project's own build goes through apelin_package_install; a dependency from the user's repositories goes through shell_run as root with irisin-cli, with the user's approval. Diagnosing a refused install or upgrade with irisin-cli's questions and dry runs, as root. Why apt and dpkg are never the way.",
        body: """
        # Installing packages

        shell_run runs as **mobile** (uid 501). Installing, removing and
        respringing act on the whole device as root, so they go through the
        dedicated tools, except the two cases below that run as root: a
        dependency's install, and Irisin's questions and dry runs.

        ## Your project's build → apelin_package_install
        A package you built installs with `apelin_package_install` (the package artifact's id
        and digest), then `apelin_package_confirm_loaded` and `apelin_package_remove`, as the
        apelin-packaging-and-install skill says. That path keeps the approval, the
        load check and the removal handle working; nothing else does. Never
        build or place a `.deb` yourself, and never install it with irisin-cli.

        ## A dependency from a repository → irisin-cli as root
        A project may depend on a package from a repository the user has (an
        injection framework, a library, a tool). Declare it in
        `package.depends` (apelin-project-description), then install it with
        shell_run and `root: true`:
        `{"argv": ["irisin-cli", "install", "--yes", "<package id>"], "root": true}`.
        `irisin-cli` installs only as root (as mobile it exits 77), and
        `--yes` because nothing can answer a prompt. In Strict and Relaxed
        mode the user approves each such call, with Face ID, Touch ID or the
        passcode; in Full mode it runs at once. Say which package and why
        before you ask. If the user declines, or the package is in none of
        their repositories, ask them to install it with their package
        manager instead, then install your build again.
        - Never `apt`, `dpkg` or `sudo`: they bypass Irisin, and newer
          bootstraps no longer ship apt or dpkg at all.
        - What `root: true` writes belongs to root, so mobile cannot change
          it afterwards. Another step that needs root follows the system
          prompt's rule for root: said first, and a change outside the
          project only with the user's go-ahead for exactly it.
        An install whose dependency is missing fails: the installer resolves
        nothing. Never drop the dependency, copy its files into your package
        or rename your package to get past it. The tweak extension depends on
        `mobilesubstrate` and the preferences extension on `preferenceloader`,
        so both are there wherever those extensions are; `projectCheck` warns
        when a support component's runtime dependency is missing from
        `package.depends`.

        ## Why Irisin refuses → its questions and dry runs, as root
        When an install, removal or upgrade fails or Irisin shows a conflict
        it does not explain, ask Irisin itself. `irisin-cli` answers only as
        root, its read-only questions too (as mobile each exits 77), so they
        take `root: true` and the same approval as any root command: say what
        you will read and why before you ask, and when the user asks you to
        request root for one of these, request it rather than sending them
        to a terminal.
        - Questions: `irisin-cli list` (`--upgradable` for the updates the
          catalogue offers), `irisin-cli show <package id>`,
          `irisin-cli search <text>`, `irisin-cli repo list`, and
          `irisin-cli dpkg-query` with `-W`, `-s`, `-L` or `-l`.
        - A change checked, never made: `irisin-cli install`,
          `irisin-cli remove` or `irisin-cli upgrade` with
          `--dry-run --yes`. `--dry-run` resolves and checks everything
          and changes nothing; `--yes` only answers the prompt, which nothing
          in shell_run can (without it the run stops after printing the
          plan). Add `--json` to read the answer field by field and
          `--verbose` for what the catalogue and the helper say.
        - Read the help (`irisin-cli <command> --help`, as root too) before a
          form not shown here. Never drop `--dry-run` to act on what you
          found, and never `--allow-system-removal`, `irisin-cli respring`,
          `irisin-cli vendor` or `irisin-cli udid`. A change the diagnosis
          points to is made in Irisin by the user, or by you as a dependency
          install above, through apelin_package_install and
          apelin_package_remove for your own packages, or as root only when
          the user explicitly asks you to make exactly that change.

        ## The toolchain and the SDK are different
        A missing **compiler toolchain** or **iPhoneOS SDK** is not a package
        dependency: set those up with `apelin_toolchain_setup` and `apelin_sdk_import`
        (which ask the user and download from Apple's catalogue and the SDK
        sources), or bind the project to an installed one with
        `apelin_project_set_environment`. The environment section of the prompt lists
        what is installed; do not look for compilers on the device.
        """,
    )
}
