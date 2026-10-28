DESCRIPTION = "MangoBoost management kernel module"
SECTION = "kernel"
LICENSE = "GPL-2.0-only & MIT"
LIC_FILES_CHKSUM = "file://${WORKDIR}/git/LICENSE;md5=b234ee4d69f5fce4486a80fdaf4a4263 \
                    file://${WORKDIR}/git/LICENSES/MIT;md5=0635ec3a6ece67bf657bda470c5947bf"

MANGO_MGMT_URI ?= "git://github.com/MangoBoost/mango-drivers.git;protocol=https;branch=main"
MANGO_MGMT_SRCREV ?= "339d5db3e8b92b53abaa6dabc237d94762b410e2"

SRC_URI = "${MANGO_MGMT_URI}"
SRCREV = "${MANGO_MGMT_SRCREV}"

S = "${WORKDIR}/git/src"

inherit module

EXTRA_OEMAKE = "KERNEL_BUILD=${STAGING_KERNEL_BUILDDIR}"
MAKE_TARGETS = "mango_mgmt"
MODULES_INSTALL_TARGET = "modules_install"
MODULES_MODULE_SYMVERS_LOCATION = "mango_mgmt"

KERNEL_MODULE_AUTOLOAD += "mango-mgmt"
