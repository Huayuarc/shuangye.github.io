extension BuiltInSkills {
    static let deviceExecutables = SkillDocument(
        name: "apelin-device-executables",
        description: "Signing a program you compiled yourself before shell_run runs it (a helper, a converter, a test program), and the entitlements one needs that uses VideoToolbox, Core Video or IOSurface, Core Image, Metal or another framework that reaches for the GPU or a media accelerator. Read before running any Mach-O you linked.",
        body: """
        # Running a program you built

        This is for an executable you compile and run yourself through
        shell_run: a helper, a converter, a test program. A tool meant to
        stay goes in a package instead: a cli project
        (apelin-project-description), whose build signs it for you, or a
        workspace's build script (apelin-external-build).

        ## Sign it, every time you link it
        A binary the toolchain linked and nothing signed is killed as it
        starts: shell_run answers exit 137 with no output. Sign it with ldid
        and this skill's entitlements before the first run, and again after
        every link, since a link writes a new file:
        1. Read this skill's file `Tool.entitlements` (apelin_skill_read with
           that file) and write it once beside the program, such as
           `tools/Tool.entitlements`; never over a cli project's
           `Packaging/Tool.entitlements`, which its build signs with.
        2. Sign: `{"argv": ["ldid", "-STool.entitlements", "converter"],
           "cwd": "tools"}`, the file joined to `-S` with no space.
        3. Run it with `command` and the same `cwd` (`./converter in.mp4
           out.gif`): an argv takes only a name on the search path, never a
           path.

        Give the compiler and ldid paths relative to the working directory,
        as the apelin-bootstrap-paths skill says for roothide. The
        environment section says whether ldid is on shell_run's PATH; when
        it is not, nothing here can sign your program, so tell the user
        rather than running it unsigned.

        ## The GPU and media frameworks
        A bootstrap withholds the IOKit user clients of the GPU, IOSurface and
        the media accelerators from an ad-hoc signed binary until its
        entitlements name them. A program signed without them starts, then
        fails inside the framework. On a device, a converter that decoded
        with VideoToolbox kept getting -6662 (`kCVReturnAllocationFailed`)
        from `CVPixelBufferCreate` because no IOSurface could be made;
        rewriting the decoder did not help, and signing it with these
        classes did. `Tool.entitlements` carries the cli template's keys,
        these classes among them under both spellings of the key,
        `com.apple.security.iokit-user-client-class` and
        `com.apple.security.exception.iokit-user-client-class`. So when a
        media or GPU call fails in a program you signed some other way, sign
        it again with this file and run it again before changing the code.

        A cli project's tool is signed with the file its product's
        `entitlements` names. The template writes both lists into it from
        version 0.1.1 of the command-line tool extension (the `version`
        under `template` in `apelin-project.json`). A project keeps the file
        it was made with, so one made from 0.1.0 has neither; if it uses
        these frameworks, copy both lists into that file from this skill's.
        That changes the build description, so Strict mode asks before its
        next build.
        """,
        files: ["Tool.entitlements": toolEntitlements],
    )

    /// Every key of the cli templates' `Packaging/Tool.entitlements`, the
    /// app template's IOKit user-client lists among them since
    /// wiki.qaq.apelin.dev.cli 0.1.1; `Scripts/check-gpu-entitlements.py`
    /// holds those lists for the app itself and its app and cli templates.
    /// A test holds the keys to the cli templates and the lists to the app
    /// template; change them there first.
    static let toolEntitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <!--
        For a program you compile and run yourself on this device. Sign it
        after every link: ldid -STool.entitlements <program>

        Every key is the cli template's. platform-application, no-sandbox,
        the storage pair and container-required = false let a tool run
        from a shell outside any container, with HOME the real home of
        whoever ran it. The IOKit user-client classes are the app
        template's list: a bootstrap withholds the GPU's and IOSurface's
        user clients from an ad-hoc signed binary until they are named.
        Both spellings of the key carry the same list.
    -->
    <plist version="1.0">
    <dict>
        <key>platform-application</key>
        <true/>
        <key>com.apple.private.security.no-sandbox</key>
        <true/>
        <key>com.apple.private.security.storage.AppBundles</key>
        <true/>
        <key>com.apple.private.security.storage.AppDataContainers</key>
        <true/>
        <key>com.apple.private.security.container-required</key>
        <false/>
        <key>com.apple.security.iokit-user-client-class</key>
        <array>
            <string>AGXCommandQueue</string>
            <string>AGXDevice</string>
            <string>AGXDeviceUserClient</string>
            <string>AGXSharedUserClient</string>
            <string>AGXGLContext</string>
            <string>AppleParavirtDeviceUserClient</string>
            <string>IOAccelerator</string>
            <string>IOAccelContext</string>
            <string>IOAccelContext2</string>
            <string>IOAccelDevice</string>
            <string>IOAccelDevice2</string>
            <string>IOAccelSharedUserClient</string>
            <string>IOAccelSharedUserClient2</string>
            <string>IOAccelSubmitter2</string>
            <string>IOGPUDeviceUserClient</string>
            <string>IOSurfaceRootUserClient</string>
            <string>IOSurfaceAcceleratorClient</string>
            <string>IOSurfaceAcceleratorParavirtClient</string>
            <string>IOMobileFramebufferUserClient</string>
            <string>AppleJPEGDriverUserClient</string>
            <string>H11ANEInDirectPathClient</string>
            <string>AppleVirtIONeuralEngineDeviceUserClient</string>
            <string>IOHIDLibUserClient</string>
            <string>IOHIDEventServiceFastPathUserClient</string>
        </array>
        <key>com.apple.security.exception.iokit-user-client-class</key>
        <array>
            <string>AGXCommandQueue</string>
            <string>AGXDevice</string>
            <string>AGXDeviceUserClient</string>
            <string>AGXSharedUserClient</string>
            <string>AGXGLContext</string>
            <string>AppleParavirtDeviceUserClient</string>
            <string>IOAccelerator</string>
            <string>IOAccelContext</string>
            <string>IOAccelContext2</string>
            <string>IOAccelDevice</string>
            <string>IOAccelDevice2</string>
            <string>IOAccelSharedUserClient</string>
            <string>IOAccelSharedUserClient2</string>
            <string>IOAccelSubmitter2</string>
            <string>IOGPUDeviceUserClient</string>
            <string>IOSurfaceRootUserClient</string>
            <string>IOSurfaceAcceleratorClient</string>
            <string>IOSurfaceAcceleratorParavirtClient</string>
            <string>IOMobileFramebufferUserClient</string>
            <string>AppleJPEGDriverUserClient</string>
            <string>H11ANEInDirectPathClient</string>
            <string>AppleVirtIONeuralEngineDeviceUserClient</string>
            <string>IOHIDLibUserClient</string>
            <string>IOHIDEventServiceFastPathUserClient</string>
        </array>
    </dict>
    </plist>
    """
}
