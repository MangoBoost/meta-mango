FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://user.cfg \
                    file://mango-uboot-env.cfg \
                    "
