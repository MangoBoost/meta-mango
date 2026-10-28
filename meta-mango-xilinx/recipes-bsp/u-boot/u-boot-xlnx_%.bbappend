FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://user.cfg \
                    file://mango-uboot-env.cfg \
                    file://0004-mtd-spi-nor-Add-SECT_4K-flag-for-mt35xu02g.patch \
                    file://0004-spi-cadence-Add-OSPI-handover-with-RPU.patch \
                    "
