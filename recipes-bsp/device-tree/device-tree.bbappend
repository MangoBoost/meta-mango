# Add our layer's files directory to Yocto's file search paths.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Add all our board-specific dtsi fragments to the source URI
# so they are available to be included by the main dts.
SRC_URI += " \
    file://fragments/versal-common.dtsi \
    file://fragments/mango-drivers-common.dtsi \
    file://fragments/mango-drivers-bnic.dtsi \
    file://fragments/mango-drivers-mgmt.dtsi \
    file://fragments/mango-drivers-smi.dtsi \
    file://fragments/rpu-resources.dtsi \
    file://mango-versal-lp-generic.dtsi \
"

# --- Machine-Specific DTSI Includes ---
# Using machine overrides is the most robust way to handle this.
# This avoids variable expansion timing issues and centralizes the logic.
# A custom variable is used here which is then read by a python function.
DTSI_FRAGMENTS:mango-versal-lp-generic = "mango-versal-lp-generic.dtsi"

# This python function reads our custom DTSI_FRAGMENTS variable
# and appends the necessary include directives to the common system-user.dtsi file.
python do_patch:append() {
    debug_enabled = False

    machine = d.getVar('MACHINE', True)
    common_user_dts_path = os.path.join(d.getVar('WORKDIR'), 'system-user.dtsi')
    fragments_str = d.getVar('DTSI_FRAGMENTS', True) or ""

    if debug_enabled:
        bb.plain(f"### DEBUG: device-tree.bbappend for MACHINE: {machine} ###")
        bb.plain(f"# Fragments to include: {fragments_str}")

    if not fragments_str:
        if debug_enabled:
            bb.note(f"DTSI_FRAGMENTS is not set for {machine}, skipping dtsi include.")
        return

    fragments = fragments_str.split()

    if os.path.exists(common_user_dts_path):
        with open(common_user_dts_path, 'a') as f:
            for fragment in fragments:
                if debug_enabled:
                    bb.note(f"Including DT fragment for {machine}: {fragment}")
                f.write('\n')
                f.write(f'/include/ "{fragment}"\n')
    else:
        bb.error(f"Common system-user.dtsi not found at {common_user_dts_path}. Cannot apply board-specific overlay.")

    if debug_enabled:
        bb.plain(f"##############################################################")
}
