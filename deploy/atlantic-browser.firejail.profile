# Atlantic Browser — Firejail confinement profile.
#
# Optional firejail profile loaded by /usr/bin/atlantic-browser only when
# ATLANTIC_ENABLE_SAILJAIL=1 (NOT the default — the default confinement is
# Sailjail, applied by the .desktop entry). Applied via
# `firejail --profile=/etc/firejail/atlantic-browser.profile`.
#
# REPLACES the previous bwrap-based WebKit sandbox (build iteration 213-227)
# which was incompatible with the libhybris/Adreno GPU stack on Sailfish OS
# because bwrap's user namespace strips supplementary groups (graphics,
# video, audio) required by the Android GPU HAL, and bwrap's mount namespace
# hides separate mount points like /odm and /vendor/firmware_mnt on kernel
# 4.14.  Firejail preserves all supplementary groups and does not create a
# mount namespace, so the WPE rendering path works as normal.
#
# The untrusted web content is no longer nested-sandboxed by bwrap; the
# firejail profile confines the entire browser process instead.
#
# On-device tightening roadmap:
#  - Use `firejail --debug` to discover denied syscalls/paths.
#  - Add `read-only /usr`, `read-only /opt` etc.
#  - Add explicit whitelists instead of broad noblacklist.
#  - Consider `private-dev` with keep-dev-* for GPU nodes (needs firejail 0.9.72+).

# ── Capabilities ────────────────────────────────────────────────────────────
# Drop ALL capabilities.  Without nested bwrap, CAP_SYS_ADMIN is no longer
# required.  This is a substantial security improvement over the previous
# `caps.keep sys_admin` posture.
caps.drop all

# ── Seccomp ─────────────────────────────────────────────────────────────────
seccomp

# ── Privilege escalation ────────────────────────────────────────────────────
nonewprivs

# ── Namespace isolation ─────────────────────────────────────────────────────
ipc-namespace

# ── Temporary filesystem ───────────────────────────────────────────────────
private-tmp

# ── Filesystem: blacklist sensitive system paths ────────────────────────────
blacklist /root
blacklist /boot
blacklist /lost+found
blacklist /sbin
blacklist /usr/sbin
blacklist /usr/local/sbin

# ── Browser data directories ────────────────────────────────────────────────
mkdir ${HOME}/.local/share/org.atlantic/atlanticbrowser
mkdir ${HOME}/.cache/org.atlantic/atlanticbrowser
mkdir ${HOME}/.config/atlantic-browser
whitelist ${HOME}/.local/share/org.atlantic/atlanticbrowser
whitelist ${HOME}/.cache/org.atlantic/atlanticbrowser
whitelist ${HOME}/.config/atlantic-browser
whitelist ${HOME}/Downloads

# ── Runtime (Wayland, D-Bus, PulseAudio) ────────────────────────────────────
whitelist /run/user/100000
whitelist /run/display
