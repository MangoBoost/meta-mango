SUMMARY = "Provisioning-only PLM that serves eFUSE writes over IPI"
DESCRIPTION = "A second Versal PLM, built only to host the XilNvm eFUSE write \
server the provisioning app talks to over IPI. Deployed as plm-prov.elf and \
NEVER part of any product image - the shipped plm.elf keeps the stock defaults, \
where the NVM handlers are excluded and every eFUSE write category is compiled \
out. See README.md."

# Build the stock PLM, then re-configure it. Both .inc come from BBPATH; the
# second must be explicit because plm-firmware_%.bbappend does not match this PN.
require recipes-bsp/embeddedsw/plm-firmware.inc
require ${@'recipes-bsp/embeddedsw/plm-firmware_xsct.inc' if d.getVar('XILINX_WITH_ESW') == 'xsct' else ''}

# Own deploy name, so it can never overwrite or be mistaken for the product PLM.
# Deliberately no PROVIDES = "virtual/plm" - the image must keep using that.
PLM_IMAGE_NAME = "plm-prov-${MACHINE}"

# Copy into images/linux, next to plm.elf and psmfw.elf.
PACKAGES_LIST:append = " ${PN}"
PACKAGES_LIST[plm-firmware-efuse] = "${PLM_IMAGE_NAME}.elf:plm-prov.elf"

# Configured here, not patched: versal_plm.mss lives in the shared embeddedsw
# tree, so a patch would enable eFUSE writes in the product PLM too. By
# do_configure this recipe has its own ${S} copy, so the edit is local to it.
do_configure:prepend() {
    mss="${S}/lib/sw_apps/versal_plm/data/versal_plm.mss"
    [ -f "$mss" ] || bbfatal "PLM mss not found: $mss"

    # mss_set <library> <param> <value>. Updates in place if present, else
    # inserts into the LIBRARY block. Idempotent.
    # temp-file + rename is required: ${S} is hardlinked to the shared tree.
    mss_set() {
        _lib="$1"; _name="$2"; _value="$3"
        if grep -qE "^[[:space:]]*PARAMETER[[:space:]]+${_name}[[:space:]]*=" "$mss"; then
            sed -i -E "s|^([[:space:]]*PARAMETER[[:space:]]+${_name}[[:space:]]*=[[:space:]]*).*|\1${_value}|" "$mss"
        else
            awk -v lib="$_lib" -v line=" PARAMETER ${_name} = ${_value}" '
                { print }
                $0 ~ "PARAMETER[ \t]+LIBRARY_NAME[ \t]*=[ \t]*"lib"[ \t]*$" { print line }
            ' "$mss" > "$mss.new"
            mv "$mss.new" "$mss"
        fi
        grep -qE "^[[:space:]]*PARAMETER[[:space:]]+${_name}[[:space:]]*=[[:space:]]*${_value}[[:space:]]*$" "$mss" \
            || bbfatal "failed to set ${_name} = ${_value} in $mss (is the ${_lib} LIBRARY block present?)"
    }

    # Required. Without it #define PLM_NVM_EXCLUDE is emitted, XNvm_Init() is
    # never called, and the client's requests die before any handler.
    mss_set xilplmi plm_nvm_en true

    # Upstream defaults, stated so a later hunt for space does not take them:
    # secure features; OSPI is this board's flash; auth JTAG is planned; RSA is
    # the authentication this project uses.
    mss_set xilplmi plm_secure_en true
    mss_set xilplmi plm_ospi_en true
    mss_set xilplmi plm_auth_jtag_en true
    mss_set xilplmi plm_rsa_en true

    # Space: enabling the write paths overflowed tmr_ram_cntlr_Mem by 4192 bytes.
    # None of these has a part in a one-shot burn. ECDSA is dead code here since
    # authentication is RSA-only; see README.md before trading any of it back.
    mss_set xilplmi plm_ocp_en false
    mss_set xilplmi plm_qspi_en false
    mss_set xilplmi plm_sd_en false
    mss_set xilplmi plm_usb_en false
    mss_set xilplmi plm_ecdsa_en false
    mss_set xilplmi plm_sem_en false

    # Also required: registering the module is not enough, these gate the
    # WRITE_AES_KEYS / WRITE_IV / WRITE_PPK_HASH commands in the server itself.
    # xnvm_en_write_user_efuse stays false - nothing writes user eFUSEs yet.
    mss_set xilnvm xnvm_en_write_sec_crit_efuse true
    mss_set xilnvm xnvm_en_write_key_management_efuse true
}

# Assert the macros the .mss edit is supposed to produce: a mis-configured PLM
# otherwise looks like a good build and only fails at burn time.
do_compile:append() {
    cfg=$(find ${B} -name 'xparameters.h' -o -name 'x*_bsp_config.h' 2>/dev/null)
    if [ -z "$cfg" ]; then
        bbwarn "could not find the generated BSP config headers under ${B}; the eFUSE-write assertions were skipped. Check the mss params by hand before burning."
    else
        if grep -lE '^[[:space:]]*#define[[:space:]]+PLM_NVM_EXCLUDE' $cfg >/dev/null 2>&1; then
            bbfatal "PLM_NVM_EXCLUDE is defined: the NVM handlers were excluded, so this PLM will not serve eFUSE writes."
        fi
        for m in XNVM_WRITE_SECURITY_CRITICAL_EFUSE XNVM_WRITE_KEY_MANAGEMENT_EFUSE; do
            grep -lE "^[[:space:]]*#define[[:space:]]+$m" $cfg >/dev/null 2>&1 \
                || bbfatal "$m is not defined: the xilnvm server was built without that eFUSE write category."
        done
        bbnote "provisioning PLM: NVM handlers registered, eFUSE write categories enabled"
    fi
}
