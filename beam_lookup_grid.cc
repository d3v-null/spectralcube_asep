#include <EveryBeam/beammode.h>
#include <EveryBeam/beamnormalisationmode.h>
#include <EveryBeam/pointresponse/pointresponse.h>
#include <EveryBeam/telescope/mwa.h>
#include <casacore/ms/MeasurementSets/MeasurementSet.h>
#include <casacore/tables/Tables/ScalarColumn.h>

#include <cmath>
#include <complex>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <memory>
#include <string>

static void usage(const char* argv0) {
  std::cerr
      << "Usage: " << argv0 << " --ms <ms> --beam <mwa_full_embedded_element_pattern.h5> \\\n"
      << "  [--ra0-deg <deg>] [--dec0-deg <deg>] [--step-deg <deg>] [--n <odd int>] [--freq-hz <Hz>] \\\n"
      << "  [--out <path>]\n\n"
      << "Defaults: ra0=0, dec0=-27, step=1, n=5, freq=150e6, out=beam_xx_real_grid.txt\n";
}

int main(int argc, char** argv) {
  std::string ms_path;
  std::string beam_path;
  std::string out_path = "beam_xx_real_grid.txt";

  double ra0_deg = 0.0;
  double dec0_deg = -27.0;
  double step_deg = 1.0;
  int n = 5;
  double freq_hz = 150e6;

  for (int i = 1; i < argc; ++i) {
    if ((std::strcmp(argv[i], "--ms") == 0) && i + 1 < argc) {
      ms_path = argv[++i];
    } else if ((std::strcmp(argv[i], "--beam") == 0) && i + 1 < argc) {
      beam_path = argv[++i];
    } else if ((std::strcmp(argv[i], "--out") == 0) && i + 1 < argc) {
      out_path = argv[++i];
    } else if ((std::strcmp(argv[i], "--ra0-deg") == 0) && i + 1 < argc) {
      ra0_deg = std::atof(argv[++i]);
    } else if ((std::strcmp(argv[i], "--dec0-deg") == 0) && i + 1 < argc) {
      dec0_deg = std::atof(argv[++i]);
    } else if ((std::strcmp(argv[i], "--step-deg") == 0) && i + 1 < argc) {
      step_deg = std::atof(argv[++i]);
    } else if ((std::strcmp(argv[i], "--n") == 0) && i + 1 < argc) {
      n = std::atoi(argv[++i]);
    } else if ((std::strcmp(argv[i], "--freq-hz") == 0) && i + 1 < argc) {
      freq_hz = std::atof(argv[++i]);
    } else if ((std::strcmp(argv[i], "-h") == 0) || (std::strcmp(argv[i], "--help") == 0)) {
      usage(argv[0]);
      return 0;
    } else {
      std::cerr << "Unknown/invalid arg: " << argv[i] << "\n";
      usage(argv[0]);
      return 2;
    }
  }

  if (ms_path.empty() || beam_path.empty()) {
    usage(argv[0]);
    return 2;
  }
  if (n < 1 || (n % 2) == 0) {
    std::cerr << "--n must be an odd positive integer\n";
    return 2;
  }

  casacore::MeasurementSet ms(ms_path);
  casacore::ScalarColumn<double> time_col(ms, "TIME");
  const double time0 = time_col(0);

  everybeam::Options options;
  options.coeff_path = beam_path;
  options.beam_normalisation_mode = everybeam::BeamNormalisationMode::kFull;
  options.beam_mode = everybeam::BeamMode::kFull;
  options.frequency_interpolation = false;

  everybeam::telescope::MWA beam(ms, options);
  std::unique_ptr<everybeam::pointresponse::PointResponse> pr = beam.GetPointResponse(time0);

  const int half = n / 2;

  std::ofstream out(out_path);
  if (!out) {
    std::cerr << "Failed to open output: " << out_path << "\n";
    return 1;
  }

  out << std::setprecision(10);
  out << "# EveryBeam MWA grid lookup\n";
  out << "# ms=" << ms_path << "\n";
  out << "# beam=" << beam_path << "\n";
  out << "# time0(MJDsec)=" << std::setprecision(15) << time0 << std::setprecision(10) << "\n";
  out << "# freq_hz=" << freq_hz << "\n";
  out << "# center_ra_deg=" << ra0_deg << " center_dec_deg=" << dec0_deg << "\n";
  out << "# step_deg=" << step_deg << " n=" << n << "\n";
  out << "# Columns: ra_deg dec_deg xx_real\n";

  for (int iy = -half; iy <= half; ++iy) {
    for (int ix = -half; ix <= half; ++ix) {
      const double ra_deg = ra0_deg + ix * step_deg;
      const double dec_deg = dec0_deg + iy * step_deg;
      const double ra_rad = ra_deg * M_PI / 180.0;
      const double dec_rad = dec_deg * M_PI / 180.0;

      std::complex<float> jones[4];
      pr->Response(everybeam::BeamMode::kFull, jones, ra_rad, dec_rad, freq_hz, 0, 0);

      out << ra_deg << " " << dec_deg << " " << std::real(jones[0]) << "\n";
    }
    out << "\n";  // blank line between rows (Dec steps)
  }

  std::cerr << "Wrote " << out_path << "\n";
  return 0;
}
