# Disabled patches

`bbrv3-5.15-sapphire.patch` is temporarily quarantined because it does not apply cleanly to the pinned CLO/GKI 5.15 source: its expected `tcp_bbr3.c` / `tcp_plb.c` paths and hunk contexts are not present in that source revision. The build now selects upstream BBR unless `TCP_CONG_BBR3` is actually defined in `net/ipv4/Kconfig`. Rebase and test this patch against the pinned source before moving it back to `patches/common/`.
