#!/usr/bin/env python3
"""Compare EveryBeam Jones samples against WSClean's beam-*.fits Mueller component images.

Inputs:
  1) A WSClean beam FITS prefix or explicit directory of beam fits (e.g. ebdiag_birli-0000-beam-*.fits)
  2) The output of eb_wsclean_wcs_sample (ascii table)

We interpret WSClean beam component images per:
  wsclean_src/doc/source/primary_beam_component_images.rst

WSClean stores the lower triangle of a 4x4 Hermitian Mueller-like matrix, with
real-only diagonals, and off-diagonals split into real+imag parts.

We compute the 4x4 coherency-basis matrix as:
  M = kron(J, conj(J))
where J is the 2x2 complex Jones matrix in linear pol basis.

We then compare the appropriate element of M to each beam-N image at the sampled pixels.

Usage:
  python3 compare_wsclean_mueller.py \
    --samples eb_wsclean_wcs_samples.txt \
    --beam-glob 'ebdiag_birli-0000-beam-*.fits'

Outputs:
  - Prints per-component stats (n, rms, maxabs, corr)
"""

import argparse
import glob
import math
import numpy as np
from astropy.io import fits


def wsclean_beam_index_map():
    """Return mapping: beam_index -> (row, col, part)

    part: 're' or 'im' (diag stored as re)

    Indexing per WSClean docs:
      [0]
      [1]+[ 2]i   [ 3]
      [4]+[ 5]i   [ 6]+[ 7]i   [ 8]
      [9]+[10]i   [11]+[12]i   [13]+[14]i   [15]

    This corresponds to lower triangle entries (row>=col).
    """
    m = {
        0: (0, 0, 're'),
        1: (1, 0, 're'),
        2: (1, 0, 'im'),
        3: (1, 1, 're'),
        4: (2, 0, 're'),
        5: (2, 0, 'im'),
        6: (2, 1, 're'),
        7: (2, 1, 'im'),
        8: (2, 2, 're'),
        9: (3, 0, 're'),
        10: (3, 0, 'im'),
        11: (3, 1, 're'),
        12: (3, 1, 'im'),
        13: (3, 2, 're'),
        14: (3, 2, 'im'),
        15: (3, 3, 're'),
    }
    return m


def load_samples(path):
    rows = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) != 12:
                raise ValueError(f"Expected 12 columns, got {len(parts)} in line: {line}")
            vals = list(map(float, parts))
            rows.append(vals)
    a = np.array(rows, dtype=float)
    # columns: pix_x pix_y ra_deg dec_deg J00re J00im J01re J01im J10re J10im J11re J11im
    return a


def jones_from_row(r):
    j00 = r[4] + 1j * r[5]
    j01 = r[6] + 1j * r[7]
    j10 = r[8] + 1j * r[9]
    j11 = r[10] + 1j * r[11]
    return np.array([[j00, j01], [j10, j11]], dtype=np.complex128)


def mueller_from_jones(J):
    # coherency basis ordering: [00,01,10,11] == [XX,XY,YX,YY]
    return np.kron(J, np.conjugate(J))


def corrcoef(x, y):
    x = np.asarray(x)
    y = np.asarray(y)
    if x.size < 2:
        return float('nan')
    xv = x - x.mean()
    yv = y - y.mean()
    denom = np.sqrt(np.sum(xv * xv) * np.sum(yv * yv))
    if denom == 0:
        return float('nan')
    return float(np.sum(xv * yv) / denom)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--samples', required=True)
    ap.add_argument('--beam-glob', required=True, help="Glob like 'ebdiag_birli-0000-beam-*.fits'")
    ap.add_argument('--tolerance', type=float, default=1e-6)
    args = ap.parse_args()

    sample = load_samples(args.samples)

    # Determine beam files
    files = sorted(glob.glob(args.beam_glob))
    if not files:
        raise SystemExit(f"No files matched: {args.beam_glob}")

    # Build dict beam_index->data array
    beam_data = {}
    for fn in files:
        # parse index from trailing -beam-<n>.fits
        base = fn.split('/')[-1]
        try:
            idx = int(base.split('-beam-')[-1].split('.fits')[0])
        except Exception:
            continue
        d = fits.getdata(fn)
        # expected shape (1,1,ny,nx)
        d = np.array(d)
        if d.ndim == 4:
            d2 = d[0, 0, :, :]
        elif d.ndim == 2:
            d2 = d
        else:
            d2 = d.reshape(d.shape[-2], d.shape[-1])
        beam_data[idx] = d2

    # Sanity: need at least beam-0 and beam-15 to say anything
    if 0 not in beam_data or 15 not in beam_data:
        raise SystemExit("Missing required beam planes (need at least beam-0 and beam-15)")

    idx_map = wsclean_beam_index_map()

    # For each beam-N present: compute predicted values from J and compare
    for bidx in sorted(beam_data.keys()):
        if bidx not in idx_map:
            continue
        row_i, col_j, part = idx_map[bidx]
        obs = []
        pred = []

        img = beam_data[bidx]
        ny, nx = img.shape

        for r in sample:
            pix_x = r[0]
            pix_y = r[1]
            # FITS pixels are 1-based; numpy is 0-based. Sample pix were generated in FITS pixel coords.
            ix = int(round(pix_x)) - 1
            iy = int(round(pix_y)) - 1
            if ix < 0 or ix >= nx or iy < 0 or iy >= ny:
                continue
            o = float(img[iy, ix])
            J = jones_from_row(r)
            M = mueller_from_jones(J)
            z = M[row_i, col_j]
            p = float(np.real(z) if part == 're' else np.imag(z))

            if not (math.isfinite(o) and math.isfinite(p)):
                continue
            obs.append(o)
            pred.append(p)

        obs = np.array(obs, dtype=float)
        pred = np.array(pred, dtype=float)
        if obs.size == 0:
            print(f"beam-{bidx:02d} (M[{row_i},{col_j}] {part}) : no samples")
            continue

        diff = pred - obs
        rms = float(np.sqrt(np.mean(diff * diff)))
        maxabs = float(np.max(np.abs(diff)))
        cc = corrcoef(obs, pred)
        print(f"beam-{bidx:02d} (M[{row_i},{col_j}] {part}) n={obs.size:3d} rms={rms:.6g} maxabs={maxabs:.6g} corr={cc:.6f}")

        # Flag totally-zero plane
        if np.all(np.abs(obs) < args.tolerance):
            print(f"  NOTE: beam-{bidx:02d} observed values are ~0 at all sampled pixels")


if __name__ == '__main__':
    main()
