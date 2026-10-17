# Silica OS: a bootc image on Fedora with Silica as the default session.
#
# Build (tools/build-image.sh does this and then makes a disk):
#   podman build -t localhost/silica-os:latest .
#
# The Silica packages come from silica-packages, in one of two ways:
#   - local RPMs in rpms/ (CI chaining: the packages job downloads the release assets there);
#   - SILICA_REPO_URL, the URL of the dnf `silica.repo` published with a silica-packages release.
# SILICA_PACKAGES=none builds the image without them (to check the rest of this file before the
# first packages release); the result boots to a text login, not to Silica.

ARG FEDORA_VERSION=44
FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION}

ARG SILICA_PACKAGES=required
ARG SILICA_REPO_URL=
# The user the session logs in as until the first-run assistant (D3) and the greeter (D2) exist.
ARG AUTOLOGIN_USER=silica
ARG SILICA_VERSION=0.1.2

# The system: graphics (Mesa, GBM, libinput), the seat through logind (libseat picks logind when
# there is no seatd), audio, network, Flatpak for third-party apps, fonts, portals, and greetd
# for the automatic login.
RUN dnf -y install \
        mesa-dri-drivers mesa-vulkan-drivers mesa-libgbm mesa-libEGL \
        libinput libseat xkeyboard-config libxkbcommon \
        pipewire pipewire-pulseaudio pipewire-utils wireplumber \
        NetworkManager NetworkManager-wifi \
        flatpak xdg-desktop-portal xdg-user-dirs xdg-utils \
        rsms-inter-fonts google-noto-sans-fonts google-noto-color-emoji-fonts dejavu-sans-fonts fontconfig \
        adwaita-cursor-theme \
        polkit greetd greetd-selinux \
    && dnf clean all

# Silica itself (silica-packages).
COPY rpms/ /tmp/silica-rpms/
RUN set -eu; \
    packages="silica-session ossido silica-embedder silica-daemon silica-portal silica-cli \
        silica-shell silica-flutter-engine silica-icons mustache clock calculator terminal mail settings preview"; \
    if ls /tmp/silica-rpms/*.rpm >/dev/null 2>&1; then \
        dnf -y install /tmp/silica-rpms/*.rpm; \
    elif [ -n "$SILICA_REPO_URL" ]; then \
        curl -fsSL -o /etc/yum.repos.d/silica.repo "$SILICA_REPO_URL"; \
        dnf -y install $packages; \
    elif [ "$SILICA_PACKAGES" = none ]; then \
        echo "warning: building without the Silica packages (SILICA_PACKAGES=none)"; \
    else \
        echo "error: no Silica packages: put RPMs in rpms/ or pass SILICA_REPO_URL" >&2; \
        echo "       (or SILICA_PACKAGES=none to build the base without them)" >&2; \
        exit 1; \
    fi; \
    rm -rf /tmp/silica-rpms; \
    dnf clean all

# Configuration: Applications folder, polkit, greetd, Flatpak remote, session defaults.
LABEL org.opencontainers.image.source="https://github.com/silica-os/silica-os" \
      org.opencontainers.image.title="Silica OS" \
      org.opencontainers.image.description="Silica desktop on Fedora bootc (alpha)" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0"

COPY rootfs/ /

# - /Applications for every user, on /var because /usr is read-only (silica-os#3); the directory
#   itself comes from tmpfiles.d at boot.
# - Automatic login into the Silica session (greetd's initial session); the text greeter
#   (agreety) is the fallback after logging out, until the Silica greeter (D2).
# - Flathub as a system remote, read by Flatpak from remotes.d on first use.
# - Branding: Silica on Fedora. VERSION_ID stays Fedora's: dnf and the image tools read it.
RUN set -eu; \
    ln -s var/Applications /Applications; \
    sed -i "s/@AUTOLOGIN_USER@/${AUTOLOGIN_USER}/" /etc/greetd/config.toml; \
    mkdir -p /etc/flatpak/remotes.d; \
    curl -fsSL -o /etc/flatpak/remotes.d/flathub.flatpakrepo \
        https://dl.flathub.org/repo/flathub.flatpakrepo; \
    sed -i \
        -e 's/^NAME=.*/NAME="Silica"/' \
        -e "s/^VERSION=.*/VERSION=\"${SILICA_VERSION} (alpha)\"/" \
        -e 's/^ID=.*/ID=silica/' \
        -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Silica ${SILICA_VERSION} (alpha)\"/" \
        -e 's|^HOME_URL=.*|HOME_URL="https://github.com/silica-os"|' \
        -e 's|^DOCUMENTATION_URL=.*|DOCUMENTATION_URL="https://github.com/silica-os/silica-os"|' \
        -e 's|^SUPPORT_URL=.*|SUPPORT_URL="https://github.com/silica-os/silica-os/issues"|' \
        -e 's|^BUG_REPORT_URL=.*|BUG_REPORT_URL="https://github.com/silica-os/silica-os/issues"|' \
        -e '/^LOGO=/d' -e '/^ANSI_COLOR=/d' -e '/^DEFAULT_HOSTNAME=/d' \
        /usr/lib/os-release; \
    if grep -q '^ID_LIKE=' /usr/lib/os-release; then \
        sed -i 's/^ID_LIKE=.*/ID_LIKE=fedora/' /usr/lib/os-release; \
    else \
        echo 'ID_LIKE=fedora' >> /usr/lib/os-release; \
    fi; \
    echo "IMAGE_VERSION=${SILICA_VERSION}" >> /usr/lib/os-release; \
    systemctl enable greetd.service NetworkManager.service; \
    systemctl set-default graphical.target

# Leftovers of the package installs in /run, /tmp and /var: the image must not carry state
# there (bootc copies /var only at install time).
RUN rm -rf /var/log/dnf5.log /var/cache/libdnf5 /var/cache/swcatalog /var/cache/ldconfig /var/lib/dnf \
        /run/dnf /run/selinux-policy /tmp/* /var/tmp/*

RUN bootc container lint
