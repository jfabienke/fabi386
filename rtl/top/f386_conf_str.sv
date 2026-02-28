/*
 * fabi386: MiSTer OSD Configuration String
 * ------------------------------------------
 * Defines the on-screen display menu for MiSTer framework.
 * This string is passed to hps_io and controls the OSD options
 * visible when the user presses the MiSTer menu button.
 */

package f386_conf_str_pkg;

    // MiSTer CONF_STR format: semicolon-delimited, null-terminated.
    // See MiSTer wiki: https://github.com/MiSTer-devel/Wiki_MiSTer/wiki/confstr
    localparam CONF_STR = {
        "fabi386;;",
        "-;",
        "S0,IMGVHD,Mount HDD;",
        "S1,IMGVHD,Mount Floppy;",
        "-;",
        "O[1],A20 Gate,Off,On;",
        "O[2],CPU Speed,33MHz,40MHz;",
        "-;",
        "R[0],Reset;",
        "V,v0.1"
    };

endpackage
