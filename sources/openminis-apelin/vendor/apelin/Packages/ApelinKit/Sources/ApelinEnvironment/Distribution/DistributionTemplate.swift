import Foundation

/// The files a package repository starts with, after owngoal-dev/owngoal-packages
/// (OwnGoal's own source) trimmed to what one person's repository needs: the
/// packages committed in `debs/`, indexed by GitHub Actions into `Packages`,
/// `Packages.xz` and `Release` with apt-ftparchive and published to GitHub
/// Pages on every push to the repository's branch. `__REPOSITORY__`,
/// `__SOURCE_URL__` and `__BRANCH__` are the repository's `owner/name`, its
/// Pages address and the branch its packages are pushed to.
enum DistributionTemplate {
    /// What a repository must have for Apelin to call it one; a link adds
    /// whatever of the template it lacks.
    static let workflowPath = ".github/workflows/update-repository.yml"

    /// The files Apelin keeps up to date and Update Repository… replaces;
    /// every other template file is the user's once it exists.
    static let maintained: Set<String> = [
        workflowPath, "scripts/update-repository.sh", "index.html", "README.md", "CydiaIcon.png",
    ]

    static func files(
        repository: String,
        sourceURL: String,
        branch: String,
    ) -> [(path: String, contents: Data, executable: Bool)] {
        let fill = { (text: String) in
            Data(
                text.replacingOccurrences(of: "__REPOSITORY__", with: repository)
                    .replacingOccurrences(of: "__SOURCE_URL__", with: sourceURL)
                    .replacingOccurrences(of: "__BRANCH__", with: branch)
                    .utf8,
            )
        }
        return [
            (workflowPath, fill(workflow), false),
            ("scripts/update-repository.sh", Data(updateScript.utf8), true),
            ("index.html", fill(indexPage), false),
            ("CydiaIcon.png", icon, false),
            ("README.md", fill(readme), false),
            ("debs/README.md", Data(debsReadme.utf8), false),
            ("depictions/README.md", Data(depictionsReadme.utf8), false),
            ("sileo-featured.json", Data(featured.utf8), false),
            (".gitignore", Data(gitignore.utf8), false),
        ]
    }

    static let workflow = """
    name: Build and Deploy APT Repository

    on:
      push:
        branches:
          - __BRANCH__
        paths:
          - ".github/workflows/update-repository.yml"
          - "debs/**"
          - "depictions/**"
          - "scripts/update-repository.sh"
          - "CydiaIcon.png"
          - "index.html"
          - "sileo-featured.json"
      workflow_dispatch:

    permissions:
      contents: read

    concurrency:
      group: github-pages
      cancel-in-progress: true

    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - name: Check out repository
            uses: actions/checkout@v4

          - name: Install repository tools
            run: |
              sudo apt-get update
              sudo apt-get install --yes apt-utils xz-utils qrencode

          - name: Configure GitHub Pages
            id: pages
            uses: actions/configure-pages@v5

          - name: Build repository
            env:
              REPOSITORY_NAME: ${{ github.event.repository.name }}
              REPOSITORY_OWNER: ${{ github.repository_owner }}
              SOURCE_URL: ${{ steps.pages.outputs.base_url }}
            run: ./scripts/update-repository.sh

          - name: Upload GitHub Pages artifact
            uses: actions/upload-pages-artifact@v3
            with:
              path: _site

      deploy:
        needs: build
        runs-on: ubuntu-latest
        permissions:
          pages: write
          id-token: write
        environment:
          name: github-pages
          url: ${{ steps.deployment.outputs.page_url }}
        steps:
          - name: Deploy to GitHub Pages
            id: deployment
            uses: actions/deploy-pages@v4

    """

    static let updateScript = #"""
    #!/usr/bin/env bash
    # Indexes debs/ into Packages, Packages.xz and Release and writes the site
    # GitHub Pages serves to _site/. Run by the workflow on every push to
    # main; on Debian or Ubuntu it runs the same by hand.
    set -euo pipefail

    repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "${repository_root:?}"

    for command_name in apt-ftparchive xz; do
      if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 69
      fi
    done

    name="${REPOSITORY_NAME:-$(basename "$repository_root")}"
    owner="${REPOSITORY_OWNER:-$name}"
    work_dir="$(mktemp -d "$repository_root/.repo-build.XXXXXX")"
    trap 'rm -rf -- "${work_dir:?}"' EXIT
    site_dir="$work_dir/site"
    mkdir -p "$site_dir"

    shopt -s nullglob
    packages=(debs/*.deb)
    shopt -u nullglob

    # Running from the root keeps each Filename relative: debs/<file>.deb.
    if ((${#packages[@]} > 0)); then
      apt-ftparchive packages debs > "$work_dir/Packages"
    else
      : > "$work_dir/Packages"
    fi

    # A package with no Section is filed under nothing; refuse it here.
    awk '
      BEGIN { RS = ""; FS = "\n" }
      {
        package = ""; section = ""
        for (field = 1; field <= NF; field++) {
          if ($field ~ /^Package: /) package = substr($field, 10)
          if ($field ~ /^Section: /) section = substr($field, 10)
        }
        if (package != "" && section == "") {
          printf "Package %s has no Section field, which package managers file it by.\n", package > "/dev/stderr"
          exit 1
        }
      }
    ' "$work_dir/Packages"

    xz -9e -c "$work_dir/Packages" > "$work_dir/Packages.xz"
    mkdir -p "$work_dir/indexes"
    cp "$work_dir/Packages" "$work_dir/Packages.xz" "$work_dir/indexes/"

    # Release is written beside the indexes, never among them, so it does
    # not hash itself.
    apt-ftparchive \
      -o APT::FTPArchive::Release::Origin="$owner" \
      -o APT::FTPArchive::Release::Label="$name" \
      -o APT::FTPArchive::Release::Suite="stable" \
      -o APT::FTPArchive::Release::Version="1.0" \
      -o APT::FTPArchive::Release::Codename="$name" \
      -o APT::FTPArchive::Release::Architectures="iphoneos-arm iphoneos-arm64 iphoneos-arm64e" \
      -o APT::FTPArchive::Release::Components="main" \
      -o APT::FTPArchive::Release::Description="Packages from $owner" \
      release "$work_dir/indexes" > "$work_dir/Release"

    if ((${#packages[@]} > 0)); then
      mkdir -p "$site_dir/debs"
      cp "${packages[@]}" "$site_dir/debs/"
    fi
    for file in index.html CydiaIcon.png sileo-featured.json; do
      if [[ -f "$file" ]]; then
        cp "$file" "$site_dir/"
      fi
    done
    # The home page's QR code: Irisin's add-source link for the address
    # Pages serves, which the Camera opens in Irisin. Left out without
    # qrencode or an address, and the page shows the card without it.
    source_url="${SOURCE_URL:-}"
    if [[ -n "$source_url" ]] && command -v qrencode >/dev/null 2>&1; then
      [[ "$source_url" == */ ]] || source_url="$source_url/"
      qrencode -t SVG --svg-path -m 0 --foreground=1F232B -o "$site_dir/qr.svg" \
        "irisin://repository/add?url=$source_url"
    fi
    if [[ -d depictions ]]; then
      cp -R depictions "$site_dir/depictions"
    fi
    cp "$work_dir/Packages" "$work_dir/Packages.xz" "$work_dir/Release" "$site_dir/"
    # Pages runs no Jekyll over the site.
    touch "$site_dir/.nojekyll"

    # Never on an empty path: an empty root would make this /_site.
    rm -rf -- "${repository_root:?}/_site"
    mv "$site_dir" "${repository_root:?}/_site"
    echo "Built the APT repository in _site/ (${#packages[@]} packages)"

    """#

    /// The source's home page: the repository's card as Apelin draws it
    /// (Repository Card…), centred on the page, with Open in Irisin… under
    /// it. Every line is the body size in a rounded face, set apart by
    /// weight and half opacity; the card stays light whatever the system is.
    static let indexPage = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>__REPOSITORY__</title>
    <style>
    :root { color-scheme: light; --ink: #1f232b; --page: #f2f2f7; }
    * { box-sizing: border-box; }
    html, body { height: 100%; }
    body {
      margin: 0; padding: 24px; background: var(--page); color: var(--ink);
      display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 16px;
      font: 17px/22px ui-rounded, "SF Pro Rounded", -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
    }
    .card {
      position: relative; width: min(400px, 100%); padding: 65px 32px 36px;
      background: #fff; border-radius: 24px; text-align: center;
    }
    .card::before {
      content: ""; position: absolute; top: 20px; left: 50%; width: 60px; height: 11px;
      margin-left: -30px; border-radius: 5.5px; background: var(--page);
    }
    .card img.icon { display: block; width: 64px; height: 64px; margin: 0 auto 16px; border-radius: 15px; }
    .card p { margin: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .card .title { font-weight: 700; margin-bottom: 3px; }
    .card .dim { opacity: 0.5; }
    .card img.qr { display: block; width: 248px; max-width: 100%; margin: 18px auto 30px; }
    a.open { color: #007aff; text-decoration: underline; }
    </style>
    </head>
    <body>
    <main class="card">
    <img class="icon" src="CydiaIcon.png" alt="">
    <p class="title" id="title"></p>
    <p class="dim" id="address"></p>
    <img class="qr" id="qr" src="qr.svg" alt="">
    <p class="dim">Scan with Camera to add in Irisin</p>
    <p class="dim" id="owner"></p>
    </main>
    <a class="open" id="open">Open in Irisin…</a>
    <script>
    const repository = "__REPOSITORY__";
    const source = new URL(".", location.href).href;
    const [owner, name] = repository.split("/");
    document.getElementById("title").textContent = name || repository;
    document.getElementById("address").textContent = source.replace(/^https?:[/][/]/, "").replace(/[/]+$/, "");
    document.getElementById("owner").textContent = "@" + owner;
    document.getElementById("open").href = "irisin://repository/add?url=" + encodeURIComponent(source);
    for (const image of document.querySelectorAll("img")) {
      image.addEventListener("error", () => { image.style.display = "none"; });
    }
    </script>
    </body>
    </html>

    """

    static let readme = """
    # __REPOSITORY__

    An APT source for jailbroken iOS, published with Apelin.

    Add `__SOURCE_URL__` in Irisin.

    ## How it works

    - Packages are the `.deb` files in `debs/`, named
      `<Package>_<Version>_<Architecture>.deb`. Apelin's Distribute… page
      publishes a release build here; a `.deb` pushed by hand works the same.
    - On every push to `__BRANCH__`, `.github/workflows/update-repository.yml` runs
      `scripts/update-repository.sh`, which indexes `debs/` into `Packages`,
      `Packages.xz` and `Release`, and publishes the site to GitHub Pages.
      Never commit those indexes or `_site/`.
    - `depictions/<package id>/` holds a package's depiction, icon and
      banner; `sileo-featured.json` the banners Irisin shows at the top of the
      source; `CydiaIcon.png`, when present, the source's icon.

    Pages may serve the previous index for up to ten minutes after a push.

    """

    static let debsReadme = """
    # Packages

    Put one `.deb` per package version here, named
    `<Package>_<Version>_<Architecture>.deb`, and push.

    Each package's control file needs these fields:

    ```debcontrol
    Package: com.example.tweak
    Name: Example Tweak
    Version: 1.0.0
    Architecture: iphoneos-arm64
    Description: A short description.
    Maintainer: Your Name <you@example.com>
    Author: Your Name <you@example.com>
    Section: Tweaks
    ```

    `Section` is the package's category (Tweaks, Applications, Utilities,
    Themes…); the index refuses a package without it. `Depiction`,
    `SileoDepiction` and `Icon` may point into `depictions/<package id>/`.
    Rootless packages are `iphoneos-arm64`, roothide ones `iphoneos-arm64e`.

    """

    static let depictionsReadme = """
    # Depictions

    Optional, one folder per package id: `index.html` (the web depiction),
    `depiction.json` (the native depiction Irisin shows), `icon.png` and
    `banner.png`. They are published at
    `<source>/depictions/<package id>/…`.

    """

    static let featured = """
    {
      "class": "FeaturedBannersView",
      "itemSize": "{263, 148}",
      "itemCornerRadius": 10,
      "banners": []
    }

    """

    static let gitignore = """
    .DS_Store
    .repo-build.*
    /_site/
    /Packages
    /Packages.*
    /Release
    /Release.gpg
    /InRelease

    """
}
