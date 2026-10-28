DESCRIPTION = "CLI tools for MangoBoost SDK users (prebuilt, BoostX)"
SECTION = "utils"
LICENSE = "LicenseRef-MangoBoost-Proprietary-1.0"
LIC_FILES_CHKSUM = "file://usr/share/licenses/mango-cli-boostx/LICENSE;md5=23929374febfa493de24eb9f508c82c8 \
                    file://usr/share/licenses/mango-cli-boostx/NOTICE;md5=7b89340de4fe37f3fc9db65ab88a7fce"
NO_GENERIC_LICENSE[LicenseRef-MangoBoost-Proprietary-1.0] = "usr/share/licenses/mango-cli-boostx/LICENSE"

MANGO_CLI_URI ?= "https://repo.mangoboost.io/artifactory/public-generic/petalinux-2025.2/mango-cli-boostx-${PV}-0.petalinux-2025.2-aarch64.tar.gz"
MANGO_CLI_SHA256 ?= "42dfa7c5b1c3b4a5dd13ba6980053afb4130c1e60e0b49865ca88ae6d342e902"

SRC_URI = "${MANGO_CLI_URI};subdir=${BP}"
SRC_URI[sha256sum] = "${MANGO_CLI_SHA256}"

COMPATIBLE_HOST = "aarch64.*-linux"

# Only so the shlib scan finds the provider of libglib-2.0.so.0
DEPENDS = "glib-2.0"

inherit bin_package

# The tarball carries the license agreement and the third-party notices
# under /usr/share/licenses; keep them in this package instead of a -lic
# package the image would not install.
LICENSE_CREATE_PACKAGE = "0"

# Build metadata shipped in the tarball, not part of the rootfs
do_install:append() {
    rm -f ${D}/BUILD_INFO
}

RDEPENDS:${PN} += "bash bash-completion python3-systemd"

INSANE_SKIP:${PN} = "already-stripped ldflags"
