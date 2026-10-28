# U-Boot-only device tree (built when CONFIG_SUBSYSTEM_UBOOT_EXT_DTB=y): reuse the
# board-common fragment (versal-common, same as Linux) and add the OSPI flash node
# for env. Linux DT is untouched.
FILESEXTRAPATHS:prepend := "${THISDIR}/../device-tree/files:"

SRC_URI += " file://fragments/versal-common.dtsi \
             file://fragments/lpddr4-base.dtsi \
             file://fragments/mango-drivers-smi.dtsi \
             file://fragments/rpu-resources.dtsi \
             file://fragments/ospi-flash.dtsi"

UBOOT_DT_FRAGMENTS = "fragments/versal-common.dtsi fragments/ospi-flash.dtsi"

python do_patch:append() {
    import os
    user_dtsi = os.path.join(d.getVar('WORKDIR'), 'system-user.dtsi')
    if not os.path.exists(user_dtsi):
        bb.fatal("uboot-device-tree: %s not found; cannot customize the U-Boot DT" % user_dtsi)
    with open(user_dtsi, 'a') as f:
        for frag in (d.getVar('UBOOT_DT_FRAGMENTS') or "").split():
            f.write('\n/include/ "%s"\n' % frag)
}
