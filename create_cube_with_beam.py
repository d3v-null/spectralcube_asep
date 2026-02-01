import numpy as np
import astropy.wcs as wcs
from astropy.io import fits
from astropy.time import Time
import os

# Configuration matching the notebook snippet
def main(args):
    base, suff, nch, gpstime = args[0], args[1], int(args[2]), float(args[3])
    # base = "/scratch/mwaeor/dev/gama9/1271676902/model_allsky"
    # suff = "XX-dirty"
    # nch = 64
    # gpstime = 1271676902

    print(f"Creating cube for {base} with {nch} channels...")

    # Read MFS file for geometry
    mfs_filename = f"{base}-MFS-{suff}.fits"
    if not os.path.exists(mfs_filename):
        print(f"Warning: {mfs_filename} not found, trying 0000...")
        mfs_filename = f"{base}-0000-{suff}.fits"

    with fits.open(mfs_filename) as mfs_hdu:
        # Handle data shape (checking for Stokes/Freq axes)
        data_shape = mfs_hdu[0].data.shape
        header = mfs_hdu[0].header
        im_wcs = wcs.WCS(header)

        # Assuming shape like (1, 1, Y, X) or (Y, X)
        if len(data_shape) == 4:
            ny, nx = data_shape[2], data_shape[3]
        elif len(data_shape) == 2:
            ny, nx = data_shape[0], data_shape[1]
        else:
            # Fallback
            ny, nx = data_shape[-2], data_shape[-1]

        print(f"Image shape: {nx}x{ny}")

        # Construct Output WCS
        # Replicating logic from snippet to ensure alignment
        # Note: Using header values if wcs object doesn't have simple cdelt

        cdelt1 = im_wcs.wcs.cdelt[0] if hasattr(im_wcs.wcs, 'cdelt') else header.get('CDELT1', -1.0)
        cdelt2 = im_wcs.wcs.cdelt[1] if hasattr(im_wcs.wcs, 'cdelt') else header.get('CDELT2', 1.0)
        # CDELT3 might be bandwith?
        cdelt3 = im_wcs.wcs.cdelt[2] if hasattr(im_wcs.wcs, 'cdelt') and len(im_wcs.wcs.cdelt) > 2 else header.get('CDELT3', 30720000.0)

        crval1 = im_wcs.wcs.crval[0]
        crval2 = im_wcs.wcs.crval[1]
        crval3 = im_wcs.wcs.crval[2] if len(im_wcs.wcs.crval) > 2 else header.get('CRVAL3', 0.0)

        crpix1 = im_wcs.wcs.crpix[0]
        crpix2 = im_wcs.wcs.crpix[1]

        wcs_dict = {
            'CTYPE1': 'RA---SIN',
            'CUNIT1': 'deg',
            "CDELT1": cdelt1,
            "NAXIS1": nx,
            "CRPIX1": crpix1,
            "CRVAL1": crval1,
            'CTYPE2': 'DEC--SIN',
            'CUNIT2': 'deg',
            "CDELT2": cdelt2,
            "NAXIS2": ny,
            "CRPIX2": crpix2,
            "CRVAL2": crval2,
            'CTYPE3': 'FREQ',
            'CUNIT3': 'Hz',
            "CDELT3": cdelt3 / nch,
            "NAXIS3": nch,
            "CRPIX3": 1,
            "CRVAL3": crval3 - (cdelt3 / 2),
            "RESTFRQ": crval3,
            "SPECSYS": "TOPOCENT",
        }
        input_wcs = wcs.WCS(wcs_dict)

    # Initialize cube and beam arrays
    im_cube = np.zeros((nch, ny, nx), dtype=np.float32)
    beams = []

    for i in range(nch):
        fname = f"{base}-{i:04d}-{suff}.fits"
        if i % 10 == 0:
            print(f"Reading channel {i}/{nch} from {fname}")

        try:
            with fits.open(fname) as hdu:
                # Read data
                d = hdu[0].data
                if d.ndim == 4:
                    im_cube[i, :, :] = d[0, 0, :, :]
                elif d.ndim == 2:
                    im_cube[i, :, :] = d

                # Read Beam
                h = hdu[0].header
                bmaj = h.get('BMAJ', 0.0)
                bmin = h.get('BMIN', 0.0)
                bpa = h.get('BPA', 0.0)

                # Convert to arcseconds for CASAMBM if they are in degrees (standard FITS)
                # Standard FITS BMAJ is degrees. CASAMBM usually wants arcsec.
                beams.append([bmaj * 3600.0, bmin * 3600.0, bpa])

        except FileNotFoundError:
            print(f"File not found: {fname}")
            beams.append([0.0, 0.0, 0.0]) # Handle missing file gracefully?

    # Create Primary HDU
    print("Creating HDUs...")
    hdu_out = fits.PrimaryHDU(data=im_cube, header=input_wcs.to_header())

    # Create CASAMBM Table
    beams_arr = np.array(beams, dtype=np.float32)

    # Columns for CASAMBM
    # CARTA expects BMAJ, BMIN in arcseconds, BPA in degrees
    col_bmaj = fits.Column(name='BMAJ', format='1E', array=beams_arr[:, 0], unit='arcsec')
    col_bmin = fits.Column(name='BMIN', format='1E', array=beams_arr[:, 1], unit='arcsec')
    col_bpa = fits.Column(name='BPA', format='1E', array=beams_arr[:, 2], unit='deg')

    cols = fits.ColDefs([col_bmaj, col_bmin, col_bpa])
    hdu_table = fits.BinTableHDU.from_columns(cols)
    hdu_table.header['EXTNAME'] = 'CASAMBM'
    hdu_table.header['NPOL'] = 1
    hdu_table.header['NCHAN'] = nch
    hdu_table.header['VERSION'] = 1

    # Combine and Write
    hdul = fits.HDUList([hdu_out, hdu_table])
    out_filename = f"{base}-{suff}-cube.fits"
    print(f"Writing to {out_filename}")
    hdul.writeto(out_filename, overwrite=True)
    print("Done.")

if __name__ == "__main__":
    import sys
    main(sys.argv[-4:])
