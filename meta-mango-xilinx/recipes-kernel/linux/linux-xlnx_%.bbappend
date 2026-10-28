FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://disable-rpu-resource.cfg \
    file://openamp.cfg \
    file://disable-audit.cfg \
    "
