#include <EveryBeam/beammode.h>
#include <EveryBeam/beamnormalisationmode.h>
#include <EveryBeam/pointresponse/pointresponse.h>
#include <EveryBeam/telescope/mwa.h>
#include <casacore/ms/MeasurementSets/MeasurementSet.h>
#include <casacore/tables/Tables/ScalarColumn.h>

#include <fitsio.h>

#include <cmath>
#include <complex>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

struct FitsWcsSin {
  // Only what we need for RA---SIN / DEC--SIN.
  double crpix1 = 0.0, crpix2 = 0.0;
  double crval1_deg = 0.0, crval2_deg = 0.0;
  double cdelt1_deg = 0.0, cdelt2_deg = 0.0;
  double lonpole_deg = 180.0;
  double equinox = 2000.0;

  // Pixel -> world (deg). Pixel coordinates are 1-based FITS convention.
  // We implement the SIN (orthographic) projection inverse using direction cosines.
  void PixToWorldDeg(double pix1, double pix2, double& ra_deg, double& dec_deg) const {
    // Intermediate plane coords in degrees -> radians.
    const double x_deg = (pix1 - crpix1) * cdelt1_deg;
    const double y_deg = (pix2 - crpix2) * cdelt2_deg;
    const double l = x_deg * M_PI / 180.0;
    const double m = y_deg * M_PI / 180.0;

    const double r2 = l * l + m * m;
    if (r2 > 1.0) {
      // Outside projection sphere; still return NaNs.
      ra_deg = std::numeric_limits<double>::quiet_NaN();
      dec_deg = std::numeric_limits<double>::quiet_NaN();
      return;
    }
    const double n = std::sqrt(std::max(0.0, 1.0 - r2));

    const double ra0 = crval1_deg * M_PI / 180.0;
    const double dec0 = crval2_deg * M_PI / 180.0;

    // SIN inverse (see Calabretta & Greisen 2002).
    const double sin_dec = m * std::cos(dec0) + n * std::sin(dec0);
    const double dec = std::asin(std::max(-1.0, std::min(1.0, sin_dec)));

    const double y = l;
    const double x = n * std::cos(dec0) - m * std::sin(dec0);
    const double dra = std::atan2(y, x);

    double ra = ra0 + dra;
    // Wrap to [0, 2pi)
    ra = std::fmod(ra, 2.0 * M_PI);
    if (ra < 0) ra += 2.0 * M_PI;

    ra_deg = ra * 180.0 / M_PI;
    dec_deg = dec * 180.0 / M_PI;
  }
};

static void fits_check(int status, const char* msg) {
  if (status) {
    char err_text[FLEN_STATUS];
    fits_get_errstatus(status, err_text);
    std::string s = std::string(msg) + ": " + err_text;
    throw std::runtime_error(s);
  }
}

static std::string fits_read_str(fitsfile* f, const char* key) {
  int status = 0;
  char val[FLEN_VALUE];
  char com[FLEN_COMMENT];
  fits_read_key(f, TSTRING, key, val, com, &status);
  if (status) return std::string();
  return std::string(val);
}

static double fits_read_dbl(fitsfile* f, const char* key, double def) {
  int status = 0;
  double v = def;
  char com[FLEN_COMMENT];
  fits_read_key(f, TDOUBLE, key, &v, com, &status);
  if (status) return def;
  return v;
}

static FitsWcsSin read_wsclean_sin_wcs(const std::string& fits_path) {
  FitsWcsSin w;
  fitsfile* f = nullptr;
  int status = 0;
  fits_open_file(&f, fits_path.c_str(), READONLY, &status);
  fits_check(status, "fits_open_file");

  const std::string ctype1 = fits_read_str(f, "CTYPE1");
  const std::string ctype2 = fits_read_str(f, "CTYPE2");
  if (ctype1.rfind("RA---SIN", 0) != 0 || ctype2.rfind("DEC--SIN", 0) != 0) {
    fits_close_file(f, &status);
    throw std::runtime_error("Expected CTYPE1=RA---SIN and CTYPE2=DEC--SIN; got CTYPE1=" + ctype1 + " CTYPE2=" + ctype2);
  }

  w.crpix1 = fits_read_dbl(f, "CRPIX1", 0.0);
  w.crpix2 = fits_read_dbl(f, "CRPIX2", 0.0);
  w.crval1_deg = fits_read_dbl(f, "CRVAL1", 0.0);
  w.crval2_deg = fits_read_dbl(f, "CRVAL2", 0.0);
  w.cdelt1_deg = fits_read_dbl(f, "CDELT1", 0.0);
  w.cdelt2_deg = fits_read_dbl(f, "CDELT2", 0.0);
  w.lonpole_deg = fits_read_dbl(f, "LONPOLE", 180.0);
  w.equinox = fits_read_dbl(f, "EQUINOX", 2000.0);

  fits_close_file(f, &status);
  fits_check(status, "fits_close_file");

  return w;
}

static void usage(const char* argv0) {
  std::cerr
      << "Usage: " << argv0 << " --ms <ms> --beam <mwa_full_embedded_element_pattern.h5> --wsclean-beam-fits <beam0.fits> \\\n"
      << "  [--freq-hz <Hz>] [--grid <n>] [--step-pix <pix>] [--out <path>]\n\n"
      << "Outputs: ascii table with columns: pix_x pix_y ra_deg dec_deg J00re J00im J01re J01im J10re J10im J11re J11im\n";
}

int main(int argc, char** argv) {
  std::string ms_path;
  std::string coeff_path;
  std::string wsclean_beam_fits;
  std::string out_path = "eb_wsclean_wcs_samples.txt";

  double freq_hz = 139515000.0;  // matches ebdiag_birli-0000 header CRVAL3
  int grid = 5;
  int step_pix = 64;

  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--ms") == 0 && i + 1 < argc) ms_path = argv[++i];
    else if (std::strcmp(argv[i], "--beam") == 0 && i + 1 < argc) coeff_path = argv[++i];
    else if (std::strcmp(argv[i], "--wsclean-beam-fits") == 0 && i + 1 < argc) wsclean_beam_fits = argv[++i];
    else if (std::strcmp(argv[i], "--out") == 0 && i + 1 < argc) out_path = argv[++i];
    else if (std::strcmp(argv[i], "--freq-hz") == 0 && i + 1 < argc) freq_hz = std::atof(argv[++i]);
    else if (std::strcmp(argv[i], "--grid") == 0 && i + 1 < argc) grid = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "--step-pix") == 0 && i + 1 < argc) step_pix = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
      usage(argv[0]);
      return 0;
    } else {
      std::cerr << "Unknown arg: " << argv[i] << "\n";
      usage(argv[0]);
      return 2;
    }
  }

  if (ms_path.empty() || coeff_path.empty() || wsclean_beam_fits.empty()) {
    usage(argv[0]);
    return 2;
  }
  if (grid < 1 || (grid % 2) == 0) {
    std::cerr << "--grid must be an odd positive integer\n";
    return 2;
  }

  // Read WSClean WCS from beam FITS
  FitsWcsSin wcs = read_wsclean_sin_wcs(wsclean_beam_fits);

  // Setup EveryBeam (MWA)
  casacore::MeasurementSet ms(ms_path);
  casacore::ScalarColumn<double> time_col(ms, "TIME");
  const double time0 = time_col(0);

  everybeam::Options options;
  options.coeff_path = coeff_path;
  options.beam_normalisation_mode = everybeam::BeamNormalisationMode::kFull;
  options.beam_mode = everybeam::BeamMode::kFull;
  options.frequency_interpolation = false;

  everybeam::telescope::MWA beam(ms, options);
  std::unique_ptr<everybeam::pointresponse::PointResponse> pr = beam.GetPointResponse(time0);

  std::ofstream out(out_path);
  if (!out) {
    std::cerr << "Failed to open output file: " << out_path << "\n";
    return 1;
  }

  out << std::setprecision(10);
  out << "# ms=" << ms_path << "\n";
  out << "# coeff=" << coeff_path << "\n";
  out << "# wsclean_fits=" << wsclean_beam_fits << "\n";
  out << "# time0(MJDsec)=" << std::setprecision(15) << time0 << std::setprecision(10) << "\n";
  out << "# freq_hz=" << freq_hz << "\n";
  out << "# WCS: crpix1=" << wcs.crpix1 << " crpix2=" << wcs.crpix2
      << " crval1_deg=" << wcs.crval1_deg << " crval2_deg=" << wcs.crval2_deg
      << " cdelt1_deg=" << wcs.cdelt1_deg << " cdelt2_deg=" << wcs.cdelt2_deg
      << " equinox=" << wcs.equinox << "\n";
  out << "# grid=" << grid << " step_pix=" << step_pix << "\n";
  out << "# columns: pix_x pix_y ra_deg dec_deg J00re J00im J01re J01im J10re J10im J11re J11im\n";

  const int half = grid / 2;
  for (int iy = -half; iy <= half; ++iy) {
    for (int ix = -half; ix <= half; ++ix) {
      const double pix_x = wcs.crpix1 + ix * step_pix;
      const double pix_y = wcs.crpix2 + iy * step_pix;

      double ra_deg = 0.0, dec_deg = 0.0;
      wcs.PixToWorldDeg(pix_x, pix_y, ra_deg, dec_deg);

      const double ra_rad = ra_deg * M_PI / 180.0;
      const double dec_rad = dec_deg * M_PI / 180.0;

      std::complex<float> j[4];
      pr->Response(everybeam::BeamMode::kFull, j, ra_rad, dec_rad, freq_hz, 0, 0);

      out << pix_x << " " << pix_y << " " << ra_deg << " " << dec_deg << " "
          << std::real(j[0]) << " " << std::imag(j[0]) << " "
          << std::real(j[1]) << " " << std::imag(j[1]) << " "
          << std::real(j[2]) << " " << std::imag(j[2]) << " "
          << std::real(j[3]) << " " << std::imag(j[3]) << "\n";
    }
    out << "\n";
  }

  std::cerr << "Wrote " << out_path << "\n";
  return 0;
}
