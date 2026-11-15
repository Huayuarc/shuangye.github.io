#!/usr/bin/env python3
"""Check every development extension the way the IDE will, then build it.

For each Extensions/Development/<id>/manifest.json:
  1. validate the manifest (schema and the rules beyond it);
  2. check each template: every file declared and nothing else, placeholder
     types legal for each file format, defaults valid, digest current;
  3. instantiate each template with its defaults into a scratch project and
     validate the generated apelin-project.json;
  4. build each generated project on the Mac with Xcode's iPhoneOS SDK,
     following its typed steps for every bootstrap it names (compile, link,
     bundle-resources, lipo, dsym, strip, sign), with the extension's support
     headers, stubs and rpaths. This is a stand-in for apelin-build, to prove
     the templates and stubs compile and link; it is not the device build.

--write-digests rewrites each template's digest in its manifest first.
--no-build skips step 4.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(REPOSITORY / "Documents" / "Schemas" / "Tools"))

import apelin_schema as schema  # noqa: E402

PREFIX = {"rootless": "/var/jb", "roothide": ""}
PAGES = "https://owngoal-dev.github.io/Apelin/"
SITE = REPOSITORY / "Documents" / "Site"


def extension_directories() -> list[Path]:
    return sorted(p for p in HERE.iterdir() if p.is_dir() and (p / "manifest.json").is_file())


def write_digests(extension: Path) -> None:
    path = extension / "manifest.json"
    manifest = schema.load_json(path)
    text = path.read_text()
    for template in manifest["templates"]:
        digest = schema.template_digest(extension / template["directory"], template["files"])
        pattern = re.compile(r'("id": "%s",.*?"digest": ")sha256:[0-9a-f]{64}(")' % re.escape(template["id"]), re.S)
        text, count = pattern.subn(lambda m: m.group(1) + digest + m.group(2), text, count=1)
        if count != 1:
            raise SystemExit(f"{path}: could not place the digest of {template['id']}")
    path.write_text(text)


def sample_values(manifest: dict, template: dict) -> dict:
    product = next((p["default"] for p in template["parameters"] if p["name"] == "productName"), "Sample")
    return {
        "projectName": f"{product} Project",
        "projectID": str(uuid.uuid5(uuid.NAMESPACE_URL, f"apelin:{manifest['id']}:{template['id']}")),
        "bundleID": f"com.example.{product.lower()}",
        "packageID": f"com.example.{product.lower()}",
        "deploymentTarget": "16.0",
        "architectures": manifest["requirements"]["architectures"],
        "templateExtensionID": manifest["id"],
        "templateID": template["id"],
        "templateVersion": manifest["version"],
        "templateDigest": template["digest"],
        "toolchainID": "clt-27.0-sample",
        "toolchainDigest": "sha256:" + "1" * 64,
        "sdkID": "iPhoneOS27.0-00000000",
        "sdkDigest": "sha256:" + "2" * 64,
    }


def run(argv: list[str], **kwargs) -> None:
    result = subprocess.run(argv, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(argv)}\n{result.stdout}{result.stderr}")


def expand(root: Path, globs: list[str]) -> list[Path]:
    found: list[Path] = []
    for pattern in globs:
        matches = sorted(root.glob(pattern))
        if not matches:
            raise SystemExit(f"{root}: {pattern} matches nothing")
        found += [m for m in matches if m.is_file()]
    return found


def reference_build(project_root: Path, extensions: dict[str, tuple[Path, dict]], out: Path) -> list[str]:
    project = schema.load_json(project_root / "apelin-project.json")
    sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    built = []
    configuration_name = "Release"
    configuration = project["configurations"][configuration_name]
    products = {p["id"]: p for p in project["products"]}
    swift = project["language"] == "swift"
    for bootstrap, archs in project["architectures"].items():
        build_id = f"20261017.1-{bootstrap}"
        work = out / bootstrap
        work.mkdir(parents=True)
        outputs: dict[str, Path] = {}
        bundles: dict[str, Path] = {}
        slices: dict[str, list[Path]] = {}
        objects: dict[tuple[str, str], list[Path]] = {}
        for step in project["build"]["steps"]:
            if step["type"] == "script":
                raise SystemExit("templates must not carry script steps")
            product = products[step["product"]]
            pid = product["id"]
            includes, stub_dirs, rpaths = [], [], []
            for support in product.get("extensionSupport", []):
                ext_root, manifest = extensions[support["extension"]]
                component = manifest["support"][support["component"]]
                includes += [str(ext_root / d) for d in component.get("includeDirectories", [])]
                stub = component.get("linkStubDirectories", {}).get(bootstrap)
                if stub:
                    stub_dirs.append(str(ext_root / stub))
                rpaths += [r.replace("@PREFIX@", PREFIX[bootstrap]) for r in component.get("rpaths", {}).get(bootstrap, [])]
            defines = {
                "APELIN_BUILD_ID": f'"{build_id}"',
                "APELIN_PACKAGE_ID": f'"{project["package"]["id"]}"',
                "APELIN_VERSION": f'"{project["package"]["version"]}"',
                "APELIN_PRODUCT_NAME": f'"{product["name"]}"',
                f"APELIN_BOOTSTRAP_{bootstrap.upper()}": "1",
                f"APELIN_CONFIGURATION_{configuration_name.upper()}": "1",
                **configuration.get("defines", {}),
            }
            if step["type"] == "compile":
                for arch in archs:
                    objs = []
                    if swift:
                        obj = work / f"{pid}-{arch}.o"
                        argv = ["xcrun", "--sdk", "iphoneos", "swiftc", "-sdk", sdk, "-wmo", "-c",
                                "-target", f"{arch}-apple-ios{project['deploymentTarget']}",
                                "-module-name", product["name"],
                                "-O" if configuration["optimization"] != "0" else "-Onone",
                                "-debug-prefix-map", f"{project_root}=."]
                        if configuration["debugInfo"]:
                            argv.append("-g")
                        argv += [f"-D{k}" for k in defines if k.startswith(("APELIN_BOOTSTRAP_", "APELIN_CONFIGURATION_"))]
                        argv += configuration.get("swiftFlags", []) + step.get("flags", [])
                        argv += [str(s) for s in expand(project_root, product["sources"])] + ["-o", str(obj)]
                        run(argv)
                        objs.append(obj)
                    else:
                        for source in expand(project_root, product["sources"]):
                            obj = work / f"{pid}-{arch}-{source.stem}.o"
                            argv = ["xcrun", "--sdk", "iphoneos", "clang", "-isysroot", sdk, "-arch", arch,
                                    f"-mios-version-min={project['deploymentTarget']}", f"-O{configuration['optimization']}",
                                    "-Wall", "-Wextra", "-Werror=unguarded-availability-new", "-fvisibility=hidden",
                                    f"-ffile-prefix-map={project_root}=."]
                            if configuration["debugInfo"]:
                                argv.append("-g")
                            if product.get("objcARC"):
                                argv.append("-fobjc-arc")
                            argv += [f"-D{k}={v}" for k, v in defines.items()]
                            argv += [f"-I{project_root / h}" for h in product.get("headerSearchPaths", [])]
                            argv += [f"-I{i}" for i in includes]
                            argv += configuration.get("cFlags", []) + step.get("flags", [])
                            argv += ["-c", str(source), "-o", str(obj)]
                            run(argv)
                            objs.append(obj)
                    objects[(pid, arch)] = objs
            elif step["type"] == "link":
                slices[pid] = []
                for arch in archs:
                    binary = work / f"{pid}-{arch}"
                    if swift:
                        argv = ["xcrun", "--sdk", "iphoneos", "swiftc", "-sdk", sdk,
                                "-target", f"{arch}-apple-ios{project['deploymentTarget']}"]
                        for framework in product.get("frameworks", []):
                            argv += ["-framework", framework]
                        argv += configuration.get("linkFlags", []) + step.get("flags", [])
                        argv += [str(o) for o in objects[(pid, arch)]] + ["-o", str(binary)]
                        run(argv)
                    else:
                        argv = ["xcrun", "--sdk", "iphoneos", "clang", "-isysroot", sdk, "-arch", arch,
                                f"-mios-version-min={project['deploymentTarget']}"]
                        kind = product["type"]
                        if kind == "dylib":
                            argv += ["-dynamiclib", "-install_name", product.get("installName", f"@rpath/{product['name']}.dylib")]
                        elif kind == "bundle":
                            argv += ["-bundle"]
                        argv += [f"-L{d}" for d in stub_dirs] + [f"-F{d}" for d in stub_dirs]
                        argv += [f"-Wl,-rpath,{r}" for r in rpaths]
                        for framework in product.get("frameworks", []):
                            argv += ["-framework", framework]
                        for framework in product.get("weakFrameworks", []):
                            argv += ["-weak_framework", framework]
                        argv += [f"-l{lib}" for lib in product.get("libraries", [])]
                        argv += configuration.get("linkFlags", []) + step.get("flags", [])
                        argv += [str(o) for o in objects[(pid, arch)]] + ["-o", str(binary)]
                        run(argv)
                    slices[pid].append(binary)
            elif step["type"] == "bundle-resources":
                suffix = ".app" if product["type"] == "app" else ".bundle"
                bundle = work / (product["name"] + suffix)
                bundle.mkdir()
                info = bundle / "Info.plist"
                shutil.copyfile(project_root / product["infoPlist"], info)
                run(["plutil", "-lint", str(info)])
                for key, value in (("CFBundleExecutable", product["name"]),
                                   ("CFBundleShortVersionString", project["package"]["version"]),
                                   ("CFBundleVersion", project["package"]["version"]),
                                   ("MinimumOSVersion", project["deploymentTarget"])):
                    run(["plutil", "-replace", key, "-string", value, str(info)])
                for resource in expand(project_root, product.get("resources", [])):
                    target = bundle / resource.name
                    shutil.copyfile(resource, target)
                    if resource.suffix == ".plist":
                        run(["plutil", "-convert", "xml1", str(target)])
                bundles[pid] = bundle
            elif step["type"] == "lipo":
                merged = work / product["name"]
                if pid in bundles:
                    merged = bundles[pid] / product["name"]
                run(["lipo", "-create", *map(str, slices[pid]), "-output", str(merged)])
                outputs[pid] = merged
            elif step["type"] == "dsym":
                dsym = work / (product["name"] + ".dSYM")
                result = subprocess.run(["dsymutil", str(outputs[pid]), "-o", str(dsym)], capture_output=True, text=True)
                if result.returncode != 0 or result.stderr.strip():
                    raise SystemExit(f"dsymutil: {result.stderr}")
                dwarf = next((dsym / "Contents" / "Resources" / "DWARF").iterdir())
                uuid_product = subprocess.run(["dwarfdump", "--uuid", str(outputs[pid])], capture_output=True, text=True).stdout.split()[1::4]
                uuid_dsym = subprocess.run(["dwarfdump", "--uuid", str(dwarf)], capture_output=True, text=True).stdout.split()[1::4]
                if sorted(uuid_product) != sorted(uuid_dsym):
                    raise SystemExit("dSYM UUIDs differ from the product's")
            elif step["type"] == "strip":
                run(["strip", "-S" if step.get("style") == "debug" else "-x", str(outputs[pid])])
            elif step["type"] == "sign":
                argv = ["ldid"]
                if "entitlements" in product:
                    entitlements = project_root / product["entitlements"]
                    run(["plutil", "-lint", str(entitlements)])
                    argv.append(f"-S{entitlements}")
                else:
                    argv.append("-S")
                run(argv + ["-Cadhoc", str(outputs[pid])])
        for entry in project["package"]["layout"]:
            if "product" in entry and entry["product"] not in outputs:
                raise SystemExit(f"layout names {entry['product']}, which was not built")
        for pid, path in outputs.items():
            archs_built = subprocess.run(["lipo", "-archs", str(path)], capture_output=True, text=True).stdout.split()
            if sorted(archs_built) != sorted(archs):
                raise SystemExit(f"{path}: built {archs_built}, expected {archs}")
            linked = subprocess.run(["otool", "-L", str(path)], capture_output=True, text=True).stdout
            built.append(f"{bootstrap}: {path.name} [{' '.join(archs_built)}]" +
                         "".join(f"\n      links {line.split(' (')[0].strip()}" for line in linked.splitlines()[1:]
                                 if "substrate" in line.lower() or "Preferences" in line))
    return built


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-digests", action="store_true")
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()

    extensions: dict[str, tuple[Path, dict]] = {}
    failures = 0
    for extension in extension_directories():
        if args.write_digests:
            write_digests(extension)
        manifest = schema.load_json(extension / "manifest.json")
        errors = schema.validate_manifest(manifest)
        if manifest.get("id") != extension.name:
            errors.append(f"id {manifest.get('id')} differs from the folder name")
        for lic in manifest.get("licenses", []):
            if not (extension / lic["path"]).is_file():
                errors.append(f"license {lic['path']} is missing")
        for name, component in manifest.get("support", {}).items():
            for d in component.get("includeDirectories", []):
                if not (extension / d).is_dir():
                    errors.append(f"support {name}: {d} is missing")
            for bootstrap, d in component.get("linkStubDirectories", {}).items():
                stubs = list((extension / d).rglob("*.tbd"))
                if not stubs:
                    errors.append(f"support {name}: no .tbd in {d}")
                for stub in stubs:
                    text = stub.read_text()
                    for symbol in component.get("symbols", []):
                        bare = symbol[1:]
                        if symbol.startswith("_OBJC_"):
                            bare = re.sub(r"^_OBJC_(META)?CLASS_\$_|^_OBJC_IVAR_\$_", "", symbol)
                        if bare not in text:
                            errors.append(f"support {name}: {stub.name} does not declare {symbol}")
                    expected = component.get("installNames", {}).get(bootstrap)
                    if expected and f"'{expected}'" not in text:
                        errors.append(f"support {name}: {stub.name} install name is not {expected}")
        if not errors:
            for template in manifest["templates"]:
                errors += schema.check_template(extension, template)
        if errors:
            failures += 1
            print(f"FAIL {extension.name}")
            for error in errors:
                print(f"  {error}")
            continue
        extensions[manifest["id"]] = (extension, manifest)
        print(f"ok   {extension.name} {manifest['version']}: {len(manifest['templates'])} template(s)")

    if failures:
        return 1

    with tempfile.TemporaryDirectory(prefix="apelin-w6a-templates.", dir="/private/tmp") as scratch:
        for extension, manifest in extensions.values():
            for template in manifest["templates"]:
                destination = Path(scratch) / manifest["id"] / template["id"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                schema.instantiate(extension, manifest, template, sample_values(manifest, template), destination)
                digests = schema.project_digests(destination)
                project = schema.load_json(destination / "apelin-project.json")
                # A package manager shows the extension's own icon, one Pages serves.
                icon = f"icons/{manifest['id']}.png"
                if project["package"].get("icon") != PAGES + icon or not (SITE / icon).is_file():
                    failures += 1
                    print(f"FAIL {manifest['id']}/{template['id']}: package.icon is not {PAGES}{icon}, a file in Documents/Site")
                    continue
                print(f"ok   {manifest['id']}/{template['id']}: generated project valid")
                print(f"       build      {digests['build']['digest']}")
                print(f"       packaging  {digests['packaging']['digest']}")
                if args.no_build:
                    continue
                if project["language"] == "swift" and shutil.which("xcrun") is None:
                    continue
                for line in reference_build(destination, extensions, Path(scratch) / "build" / manifest["id"] / template["id"]):
                    print(f"       built {line}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
