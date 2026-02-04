#!/usr/bin/env python3
"""Compare two 1-source model MSes (e.g. hyperdrive vs DP3 predict).

Prints:
- mean(|DATA|) overall
- mean(|DATA|) per correlation (XX,XY,YX,YY)
- first N rows: (ant1,ant2,time,chan0 XX) for quick sanity

Usage:
  python3 compare_1src_ms.py <ms_a> <ms_b> [--n 10]

Notes:
- Assumes 4 correlations.
- Uses casacore.tables.
"""

import argparse
import numpy as np
from casacore.tables import table


def stats(ms):
    t = table(ms)
    data = t.getcol('DATA')  # shape (nrow, nchan, ncorr)
    # some MS might store (nrow, ncorr, nchan); handle by heuristics
    if data.ndim != 3:
        raise RuntimeError(f"Unexpected DATA ndim {data.ndim}")

    # determine corr axis
    # pick axis with size 4
    if data.shape[2] == 4:
        d = data
    elif data.shape[1] == 4:
        d = np.transpose(data, (0, 2, 1))
    else:
        raise RuntimeError(f"Can't find correlation axis in shape {data.shape}")

    absd = np.abs(d)
    mean_all = float(absd.mean())
    mean_corr = [float(absd[:, :, i].mean()) for i in range(4)]

    ant1 = t.getcol('ANTENNA1')
    ant2 = t.getcol('ANTENNA2')
    time = t.getcol('TIME')

    return {
        'nrow': t.nrows(),
        'nchan': d.shape[1],
        'mean_all': mean_all,
        'mean_corr': mean_corr,
        'ant1': ant1,
        'ant2': ant2,
        'time': time,
        'data': d,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ms_a')
    ap.add_argument('ms_b')
    ap.add_argument('--n', type=int, default=10)
    args = ap.parse_args()

    A = stats(args.ms_a)
    B = stats(args.ms_b)

    print(f"A: {args.ms_a}")
    print(f"  nrow={A['nrow']} nchan={A['nchan']} mean(|DATA|)={A['mean_all']}")
    print(f"  mean per corr [XX,XY,YX,YY]={A['mean_corr']}")

    print(f"B: {args.ms_b}")
    print(f"  nrow={B['nrow']} nchan={B['nchan']} mean(|DATA|)={B['mean_all']}")
    print(f"  mean per corr [XX,XY,YX,YY]={B['mean_corr']}")

    # Compare ratios
    if A['mean_all'] != 0:
        print(f"Ratio B/A (mean abs) = {B['mean_all']/A['mean_all']}")

    # First N matching rows
    n = min(args.n, A['nrow'], B['nrow'])
    print("\nFirst rows: ant1 ant2 time  A(chan0,XX)  B(chan0,XX)  ratio")
    for i in range(n):
        a = A['data'][i, 0, 0]
        b = B['data'][i, 0, 0]
        r = (b/a) if a != 0 else np.nan
        print(f"{A['ant1'][i]:3d} {A['ant2'][i]:3d} {A['time'][i]:.3f}  {a.real:+.6e}{a.imag:+.6e}j  {b.real:+.6e}{b.imag:+.6e}j  {r}")


if __name__ == '__main__':
    main()
