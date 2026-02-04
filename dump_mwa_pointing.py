#!/usr/bin/env python3
"""Dump MWA pointing metadata from an MS for debugging EveryBeam users (DP3/WSClean).

Prints:
- FIELD PHASE_DIR / DELAY_DIR / REFERENCE_DIR (deg)
- OBSERVATION MWA_GPS_TIME, TELESCOPE_NAME
- MWA_TILE_POINTING DIRECTION + DELAYS (deg)
- POINTING table status

Usage:
  python3 dump_mwa_pointing.py <ms>
"""

import sys
import numpy as np
from casacore.tables import table


def deg(x):
    return np.array(x) * 180.0 / np.pi


def main(ms):
    print(f"MS: {ms}")

    t = table(ms)
    print(f"MAIN rows={t.nrows()} cols={len(t.colnames())}")

    # OBSERVATION
    try:
        obs = table(ms + '/OBSERVATION')
        gps = obs.getcol('MWA_GPS_TIME')[0] if 'MWA_GPS_TIME' in obs.colnames() else None
        tel = obs.getcol('TELESCOPE_NAME')[0] if 'TELESCOPE_NAME' in obs.colnames() else None
        tr = obs.getcol('TIME_RANGE')[0] if 'TIME_RANGE' in obs.colnames() else None
        print("OBSERVATION:")
        print("  TELESCOPE_NAME:", tel)
        print("  MWA_GPS_TIME:   ", gps)
        print("  TIME_RANGE:     ", tr)
    except Exception as e:
        print("OBSERVATION: missing or unreadable:", e)

    # FIELD
    try:
        fld = table(ms + '/FIELD')
        print("FIELD:")
        for col in ['PHASE_DIR', 'DELAY_DIR', 'REFERENCE_DIR']:
            if col in fld.colnames():
                v = fld.getcol(col)
                # shape (nrow, npoly, 2)
                v0 = v[0, 0, :]
                print(f"  {col} rad {v0}  deg {deg(v0)}")
    except Exception as e:
        print("FIELD: missing or unreadable:", e)

    # POINTING
    try:
        pt = table(ms + '/POINTING')
        print(f"POINTING: rows={pt.nrows()} cols={len(pt.colnames())}")
        if pt.nrows() > 0 and 'DIRECTION' in pt.colnames():
            d = pt.getcol('DIRECTION')
            print("  first DIRECTION rad", d[0], "deg", deg(d[0]))
    except Exception as e:
        print("POINTING: missing or unreadable:", e)

    # MWA_TILE_POINTING
    try:
        mtp = table(ms + '/MWA_TILE_POINTING')
        print(f"MWA_TILE_POINTING: rows={mtp.nrows()} cols={mtp.colnames()}")
        if mtp.nrows() > 0:
            if 'DIRECTION' in mtp.colnames():
                d = mtp.getcol('DIRECTION')[0]
                print("  DIRECTION rad", d, "deg", deg(d))
            if 'DELAYS' in mtp.colnames():
                delays = mtp.getcol('DELAYS')[0]
                print("  DELAYS:", delays)
    except Exception as e:
        print("MWA_TILE_POINTING: missing or unreadable:", e)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: dump_mwa_pointing.py <ms>")
        raise SystemExit(2)
    main(sys.argv[1])
