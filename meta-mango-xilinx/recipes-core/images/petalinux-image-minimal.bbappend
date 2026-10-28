IMAGE_INSTALL:append:mango-versal-lp-boostx-base = " mango-cli-boostx mango-mgmt"

# Root logs in on the serial console and over SSH without a password, as
# the BoostX user guide states; set one with passwd on first login.
IMAGE_FEATURES:append = " debug-tweaks empty-root-password serial-autologin-root"

# bash, not sh: the mango-ctl completion defines functions with a dash in
# the name, which POSIX-mode bash rejects.
EXTRA_USERS_PARAMS:append = " usermod -s /bin/bash root;"
