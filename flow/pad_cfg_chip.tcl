# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Chip pad configuration: the default LibreLane pad_cfg.tcl, plus the
# one thing it only does on request -- placing the top-level I/O
# terminals (BTerms) onto the pads' bond-pad pins.
#
# Without PAD_PLACE_IO_TERMINALS the pads place but every chip port is
# left unplaced, and global placement stops with GPL-0326 ("toplevel
# port is not placed").  The PDK's sg13g2_io config.tcl carries the
# variable as a commented-out hint; the pad-side pin on every
# sg13g2_IOPad* master is `pad`.
#
# Only the signal-pad masters appear here: the chip RTL declares no
# power ports (power arrives at PNR), so the supply pads have no BTerms
# to place.  Variant 1 has no JTAG, so no tri-state TDO pad is present,
# but the tri-state master is left in the list harmlessly (the QSPI
# InOut pads are the tri-state-capable masters this chip actually uses).
set ::env(PAD_PLACE_IO_TERMINALS) "\
    sg13g2_IOPadIn/pad\
    sg13g2_IOPadOut4mA/pad\
    sg13g2_IOPadInOut4mA/pad\
"
source $::env(SCRIPTS_DIR)/openroad/common/pad_cfg.tcl
