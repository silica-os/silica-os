# App bundles, disk images and the Applications folders

Status: version 1, implemented in silica-desktop (`crates/apps`, `crates/bundle`,
`crates/launch`, the daemon's `Apps1`, `Trust1`, `Volumes1` and `Updates1`). Design:
silica-os#3. The services are specified in silica-desktop `docs/spec/launch-services.md`,
`launch.md`, `trust.md`, `volumes.md` and `updates.md`.

Silica installs apps the way the reference desktop does: an app is one folder, `Name.app`, that
the user drags into Applications and drags to the Trash to remove. Apps are distributed in a
disk image, `Name.sxv`, that opens as a window with the app and an alias of Applications.
Flathub stays the store; AppImages are accepted as they are.

## 1. The bundle: `Name.app`

```
Name.app/
  Contents/
    Info.toml                 the app's description (section 2)
    bin/                      executables (native apps)
    app/                      the Flutter bundle: flutter_assets/, libapp.so (Flutter apps)
    lib/                      private libraries not in the runtime
    Resources/
      icon/                   the app icon in the silica-icons format: icon.assets
                              (layered, composed by the daemon) or icon.png
      documents/              document icons (<name>.svg, see silica-desktop docs/thumbnails.md)
      l10n/                   translations the app loads itself
    _Signature/
      manifest                every file of Contents/ but _Signature/ (section 4)
      manifest.sig            minisign signature of manifest (Ed25519, prehashed)
      developer.pub           the developer's minisign public key
      developer.cert          optional: the developer key signed by the Silica developer CA
```

The bundle is a plain directory: it can be copied, renamed and moved; the app keeps its id
(the id is read from `Info.toml`, never from the folder name). Mustache shows it as one item.

Rules a valid bundle follows (the registry ignores bundles that break them, and `silica-bundle
verify` reports them):

- `Contents/Info.toml` exists, is at most 64 KiB and parses (section 2).
- No path inside `Contents/` contains a newline or a backslash, no symbolic link points outside
  `Contents/` (absolute targets and `..` past the top are refused), and there are no device
  files, sockets or FIFOs.
- `exec` (section 2) names a file inside `Contents/`.

## 2. `Info.toml` version 1

```toml
format = 1
id = "dev.example.Hello"            # reverse DNS; the Wayland app id; ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$
name = "Hello"
"name.it" = "Ciao"                  # one key per language, as Name[it] in a desktop entry
version = "1.2.0"                   # shown to the user
build = 42                          # monotonic; updates compare this
minimum_silica = "0.2.0"            # the oldest Silica that runs it
kind = "flutter"                    # flutter | native
runtime = "dev.silica.Platform//1"  # or "org.freedesktop.Platform//24.08", or "none"
exec = "app"                        # native: the executable (bin/hello); flutter: the Flutter
                                    # bundle folder (default "app")
args = ["--size", "248x412"]        # extra arguments (flutter: embedder options)
categories = ["Utility"]            # freedesktop categories
keywords = ["hello", "greeting"]    # optional, for search
url_schemes = ["hello"]             # handled URL schemes (x-scheme-handler/hello)
generic_name = "Greeter"            # optional: GenericName of its desktop entry
comment = "Says hello"              # optional: Comment of its desktop entry
share = false                       # optional: a target of the Share menu (X-Silica-Share)

[types]                             # the MIME types it opens, with its role
"text/x-hello" = "editor"           # editor | viewer

[documents]                         # optional: document icons, Resources/documents/<name>
"text/x-hello" = "hello"

[permissions]
network = false                     # network access
devices = "gpu"                     # none | gpu | all
filesystem = ["xdg-documents"]      # host folders (section 2.1)
talk = ["org.example.Service"]      # extra D-Bus names it may call
background = false                  # may keep running without windows

[update]
feed = "https://example.org/hello/feed.toml"

[developer]
name = "Example Ltd"
key = "RWQ…"                        # the minisign public key (base64 line); equals developer.pub
```

Required: `format`, `id`, `name`, `version`, `build`, `kind`, `runtime`, `developer.name`,
`developer.key`. Unknown keys are ignored (a newer format adds keys; `format` changes only
when the meaning of existing keys changes, and a reader refuses a `format` it does not know).

`kind`:

- `flutter`: the app is a Flutter bundle run by the Silica embedder (`silica-app`) of the
  runtime. Only valid with `runtime = "dev.silica.Platform//1"`.
- `native`: `exec` is an ELF executable, linked against the runtime's libraries (after
  silica-desktop#254, against `libvetro`). Valid with every runtime.

`runtime`:

- `dev.silica.Platform//1`: the Silica platform, branch 1: the embedder and the Flutter engine
  today, libvetro and Skia after silica-desktop#254. Branch 1 promises the embedder's command
  line and protocols of Silica 1.x. It is also a Flatpak runtime of that name, built on
  `org.freedesktop.Platform//24.08` from silica-desktop's `data/flatpak/dev.silica.Platform.yml`
  (`cargo xtask platform-runtime --build`, silica-desktop#258): when it is installed,
  `silica-launch` gives sandboxed bundles its files as `/usr`, so the same bundle runs on any
  distribution with Flatpak; when it is not, the platform is the image's own `/usr` (Silica OS
  ships no copy of it).
- `org.freedesktop.Platform//<branch>`: a Flatpak runtime installed from Flathub
  (`/var/lib/flatpak/runtime/…/active/files`); for native apps built with the freedesktop SDK.
- `none`: the bundle carries everything (`lib/`); the sandbox gets an empty `/usr` but for the
  dynamic loader of the image.

### 2.1 Permissions

| Key | Values | Default | In the sandbox |
| --- | --- | --- | --- |
| `network` | bool | false | false: a private network namespace (loopback only) |
| `devices` | `none`, `gpu`, `all` | `gpu` | `gpu`: `/dev/dri`; `all`: every device |
| `filesystem` | list | empty | each item is bound into the sandbox |
| `talk` | list of bus names | empty | callable through the D-Bus proxy |
| `background` | bool | false | allowed to run without windows |

`filesystem` items: `home`, `xdg-documents`, `xdg-download`, `xdg-music`, `xdg-pictures`,
`xdg-videos`, `xdg-desktop`, `xdg-config/<sub>`, `xdg-data/<sub>`, `/absolute/path` (not under
`/usr`, `/etc`, `/proc`, `/sys`, `/dev`, `/run`), each optionally followed by `:ro`. Everything
else reaches the app through the portals (the Open and Save dialogs, the document portal).

## 3. Folders

| Folder | Who writes | Kind in the registry |
| --- | --- | --- |
| `/usr/Applications` | the image (RPMs); read-only | `system` |
| `/Applications` → `/var/Applications` | `wheel` (setgid group); others through polkit `dev.silica.applications.install` | `bundle` |
| `~/Applications` | the user | `bundle` |
| `/var/lib/silica-dev/Applications` | `cargo xtask os deploy` (development VM only, root-owned) | `system` |

`/usr/Applications` replaces `/usr/lib64/silica/apps`: Silica's own apps are bundles there,
signed by the Silica release key, and run without a sandbox (they are part of the system:
the Terminal and the file manager need the whole computer). Each still installs a desktop
entry in `/usr/share/applications` (with `X-Silica-Bundle=`), so tools outside Silica find it.

### 3.1 Silica's own apps

Every app of Silica is a bundle in `/usr/Applications` (silica-packages; in the development
VM, `/var/lib/silica-dev/Applications`), built from its repository's `linux/Info.toml.in`.
They run unsandboxed because they are system apps, never because of their permissions: their
`[permissions]` say what a copy outside the system folders (which is a plain bundle, and runs
sandboxed) is given, and that copy works only as far as the sandbox allows.

| App | Bundle | Permissions of a copy | Why it must run from the system folder |
| --- | --- | --- | --- |
| Mustache | `Mustache.app` | `home`, `/media`, `/mnt`, background | the file manager: every file, the volumes, the desktop's icons (`--desktop`, started by the session from the bundle) and the Open and Save dialogs (the portal runs the bundle's embedder command directly, with `--helper`) |
| Mail | `Mail.app` | network, `xdg-download`, talks to `dev.frascella.Mail`, Share target | its engine, `silica-mail-engine`, stays a system D-Bus service (`dev.frascella.Mail`, activated on demand) outside the bundle |
| Terminal | `Terminal.app` | network, every device, `home` | runs the user's shell and its programs, with a pseudo-terminal |
| Settings | `Settings.app` | `home` | the system bus (network, Bluetooth, power) and polkit actions: a sandboxed copy has no system bus |
| Preview | `Preview.app` | none (the files it opens are bound) | viewer of images and PDF |
| Text Editor | `Text Editor.app` | none (the files it opens are bound) | editor of plain and rich text |
| Clock, Calculator, Notes | `<Name>.app` | none | |

Mustache shows the three folders as one Applications view, plus the Flatpak apps as virtual
items; system apps cannot be moved to the Trash.

App data stays in `~/.var/app/<id>` after the app is removed (Settings › General › Storage
lists it and can delete it).

## 4. Signatures

Keys and signatures use the minisign formats (Ed25519): a key made with `silica-bundle keygen`
works with `minisign`, and the other way round.

`_Signature/manifest` is UTF-8 text:

```
silica-manifest 1
d 0755 - Resources
f 0644 3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b Info.toml
f 0755 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 bin/hello
l - 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae lib/libx.so
```

One line per entry of `Contents/` but `_Signature/` itself, sorted by the bytes of the path:
type (`f` file, `d` directory, `l` symbolic link), permission bits in octal (`-` for links),
SHA-256 of the contents (of the link target text for a link, `-` for a directory), and the path
relative to `Contents/`. Owner, times and extended attributes are not covered.

`manifest.sig` is a minisign signature of `manifest` whose trusted comment is
`silica-bundle id=<id> build=<build>`: a manifest cannot be moved to another app or replayed as
an older build without the signature failing.

Verification (`silica-bundle verify`, `Trust1`):

1. `developer.pub` parses and equals `developer.key` in `Info.toml`.
2. `manifest.sig` is valid for `manifest` with that key, and its trusted comment names the id
   and build of `Info.toml`.
3. Every entry of the manifest matches the folder, and the folder has no entry the manifest
   does not list (an extra file is tampering too).
4. `developer.cert`, when present, is a minisign signature by a key of the Silica developer CA
   (`/usr/share/silica/trust/developer-ca/*.pub`) over the `developer.pub` key line, with the
   trusted comment `silica-developer name=<developer.name>`. Valid: the developer is
   *verified*; absent: *self-signed*. A key listed in the signed revocation list is *revoked*.

The CA, its revocation list and notarization are specified in silica-desktop
`docs/spec/trust.md` and come later (silica-os#3, phase 7): until then every bundle is
self-signed but Silica's own apps, signed by the release key, which the image lists as a CA
key.

## 5. Disk images: `Name.sxv`

The Silica eXecutable Volume is how apps are distributed, like a DMG: one read-only,
compressed file that opens as a window with the app, an alias of Applications and a
background.

Layout (little endian):

```
offset 0      header, 4096 bytes
  0   8   magic "SILICAXV"
  8   2   version (1)
  10  1   filesystem: 1 = EROFS, 2 = squashfs
  11  1   flags: bit 0 = has a license
  12  4   reserved (0)
  16  8   payload offset (4096)
  24  8   payload length
  32  8   signature offset (payload offset + payload length)
  40  2   volume name length (1..=255)
  42  …   volume name (UTF-8), then zeros up to 4096
4096          payload: the filesystem image
sig. offset   signature block, to the end of the file:
  u32 length + developer.pub (minisign public key file)
  u32 length + minisign signature of header ‖ payload
  u32 length + developer.cert (0 when self-signed)
```

The signature covers the header and the payload; its trusted comment is
`silica-volume name=<volume name>`. The payload is an EROFS image compressed with lz4hc (or
zstd), made by `mkfs.erofs`, mounted without privileges by `erofsfuse --offset=4096`; squashfs
with `squashfuse -o offset=4096` is the alternative for systems without erofs-utils.

Contents of the volume:

```
Name.app/                    the signed bundle
Applications                 a symbolic link to /Applications
.silica-window.toml          the window's layout (below)
.background/<image>          optional background (PNG)
LICENSE.txt                  optional: shown, and accepted, before the volume mounts
README.txt                   optional
```

`.silica-window.toml`:

```toml
width = 540           # the window's content size, pt
height = 380
background = "background.png"   # in .background/, drawn at 1x and 2x (background@2x.png)
view = "icons"        # icons | list
icon_size = 128       # pt
text_size = 13        # pt

[[item]]
name = "Hello.app"
x = 140               # the centre of the icon, pt from the top left
y = 190

[[item]]
name = "Applications"
x = 400
y = 190
```

Opening: a double click on the `.sxv` asks `Volumes1` to attach it. The daemon checks the
header and the signature (a damaged or altered image does not mount; an unsigned one mounts only
with the policy `anywhere`), shows the license when there is one, and mounts it with FUSE in
`/run/user/<uid>/silica-volumes/<volume name>`. Mustache lists the volume in its sidebar under
Locations, with an eject button, and opens the window with the layout. Dragging the app onto
Applications copies it; the copy gets the quarantine attribute (below). Mustache then offers to
eject and move the image to the Trash. An app started from the volume runs read-only and
suggests moving it to Applications.

`silica-bundle dmg` builds and signs an image. `silica-bundle pack` makes a `.silicaapp`
(a zip of `Name.app`) for developers and CI only; users get `.sxv` files.

## 6. Quarantine

Files that arrive from outside carry the extended attribute `user.silica.quarantine`:

```
1;<flags, 4 hex digits>;<time, unix seconds in hex>;<agent app id>;<origin>
```

`origin` is a URL (`https://…`, `file://…` of the disk image) with `%`, `;` and control
characters percent-encoded. Flags: `0001` saved by an app through the portal, `0002` copied
from a disk image, `0004` marked by `silica-quarantine`. The FileChooser portal backend marks
every file an app saves, Mustache marks what it copies or extracts from a disk image or
archive, and `silica-quarantine <file> [origin]` marks by hand. Downloads that do not go
through the portal (a browser writing to `~/Downloads` itself) are not marked: a known limit,
as on systems without a quarantine-aware browser.

The first launch of a quarantined app goes through `Trust1` (silica-desktop
`docs/spec/trust.md`); accepting removes the attribute.

## 7. What the image ships

- Packages: `bubblewrap`, `xdg-dbus-proxy`, `erofs-utils`, `erofs-fuse`, `fuse3`, `flatpak`
  (Containerfile), and silica-packages' `silica-apps`: `silica-launch`, `silica-bundle`,
  `silica-quarantine`, `/usr/libexec/silica/silica-applications-helper`, `/usr/Applications/`,
  `/usr/share/silica/runtimes/dev.silica.Platform/1/metadata` (the platform runtime, whose files
  are the image's `/usr`), the folder of the developer CA keys, the polkit action
  `dev.silica.trust.override` (Open Anyway) and the MIME types `application/x-silica-volume`
  (`*.sxv`, magic `SILICAXV`) and `application/x-silica-app-archive` (`*.silicaapp`).
- Silica's own apps as bundles in `/usr/Applications` (silica-packages, § 3.1), each with a
  desktop entry in `/usr/share/applications` carrying `X-Silica-Bundle=`.
- The polkit action `dev.silica.applications.install`, whose `exec.path` is the helper (this
  repository, `rootfs/`).
- The tmpfiles entry for `/var/Applications` and the `/Applications` link.
- Later: `/usr/share/silica/trust/developer-ca/silica-release.pub`, the public key Silica's
  bundles are signed with, once the release key exists (its secret half stays with the release
  pipeline). Until then Silica's own apps are trusted by their folder, `/usr/Applications`.
