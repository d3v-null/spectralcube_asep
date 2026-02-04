#include <EveryBeam/beammode.h>
#include <EveryBeam/beamnormalisationmode.h>
#include <EveryBeam/pointresponse/pointresponse.h>
#include <EveryBeam/telescope/mwa.h>

#include <casacore/casa/Arrays/Array.h>
#include <casacore/casa/Arrays/Matrix.h>
#include <casacore/casa/Arrays/Vector.h>
#include <casacore/casa/Quanta/MVTime.h>
#include <casacore/ms/MeasurementSets/MeasurementSet.h>
#include <casacore/ms/MeasurementSets/MSColumns.h>
#include <casacore/tables/Tables/ScalarColumn.h>

#include <cmath>
#include <complex>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

static void usage(const char* argv0) {
  std::cerr
      << "Usage: " << argv0 << " --ms <ms> --beam <mwa_full_embedded_element_pattern.h5> \\\n"
      << "  --src-ra-deg <deg> --src-dec-deg <deg> [--flux-jy <I>] \\\n"
      << "  [--row <rowIndex>] [--chan <chanIndex>] [--obs-ms <ms2>]\n\n"
      << "Computes a 1-source predicted visibility for one MS row+channel using EveryBeam Jones and MS UVW+phase centre.\n"
      << "If --obs-ms is given, also reads observed DATA from that MS at the same row+chan for comparison.\n";
}

static inline double deg2rad(double x) { return x * M_PI / 180.0; }

// Direction cosines of (ra,dec) relative to (ra0,dec0)
static void radec_to_lmn(double ra, double dec, double ra0, double dec0, double& l, double& m, double& n) {
  const double dra = ra - ra0;
  const double sin_dec = std::sin(dec);
  const double cos_dec = std::cos(dec);
  const double sin_dec0 = std::sin(dec0);
  const double cos_dec0 = std::cos(dec0);

  l = cos_dec * std::sin(dra);
  m = sin_dec * cos_dec0 - cos_dec * sin_dec0 * std::cos(dra);
  n = sin_dec * sin_dec0 + cos_dec * cos_dec0 * std::cos(dra);
}

static std::complex<double> phase_from_uvw(const casacore::Vector<double>& uvw_m, double freq_hz,
                                          double l, double m, double n) {
  constexpr double c = 299792458.0;
  const double u_l = uvw_m[0] * freq_hz / c;
  const double v_l = uvw_m[1] * freq_hz / c;
  const double w_l = uvw_m[2] * freq_hz / c;

  const double arg = -2.0 * M_PI * (u_l * l + v_l * m + w_l * (n - 1.0));
  return std::complex<double>(std::cos(arg), std::sin(arg));
}

static casacore::Vector<double> get_chan_freqs(const casacore::MeasurementSet& ms, int spw) {
  casacore::MSColumns cols(ms);
  // MSSpWindowColumns is non-copyable; use the reference returned by MSColumns.
  auto& spwCols = cols.spectralWindow();
  casacore::Array<double> af = spwCols.chanFreq()(spw);
  casacore::Vector<double> v;
  v.assign(af);
  return v;
}

static casacore::Vector<double> get_phase_dir(const casacore::MeasurementSet& ms, int fieldId) {
  casacore::MSColumns cols(ms);
  auto& fieldCols = cols.field();
  const casacore::Array<double> a = fieldCols.phaseDir()(fieldId);
  const casacore::IPosition shp = a.shape();

  casacore::Vector<double> v(2);
  // Common shapes:
  // - (2, npoly)
  // - (npoly, 2)
  // - (npoly, 1, 2) (Python dump often shows (1,1,2) after squeezing)
  // We'll flatten and take the first 2 values in RA,DEC order where possible.

  if (shp.nelements() == 2) {
    if (shp[0] == 2) {
      casacore::Matrix<double> m; m.assign(a);
      v[0] = m(0, 0); v[1] = m(1, 0);
      return v;
    }
    if (shp[1] == 2) {
      casacore::Matrix<double> m; m.assign(a);
      v[0] = m(0, 0); v[1] = m(0, 1);
      return v;
    }
  }

  // Fallback: flatten
  casacore::Vector<double> flat;
  flat.assign(a);
  if (flat.size() >= 2) {
    v[0] = flat[0];
    v[1] = flat[1];
    return v;
  }

  throw std::runtime_error("Unexpected FIELD::PHASE_DIR shape");
}

static void print_vis4(const std::string& label, const std::complex<double> v[4]) {
  std::cerr << label << " [XX,XY,YX,YY]=";
  for(int i=0;i<4;i++) {
    std::cerr << (i==0?"":" ") << std::setprecision(10) << std::showpos
              << v[i].real() << v[i].imag() << "j";
  }
  std::cerr << std::noshowpos << "\n";
}

static void read_data_row_chan(const std::string& ms_path, size_t row, int chan, std::complex<double> out[4]) {
  casacore::MeasurementSet ms(ms_path);
  casacore::ROScalarColumn<int> ddidCol(ms, "DATA_DESC_ID");
  const int ddid = ddidCol(row);
  casacore::MSColumns cols(ms);
  const int spw = cols.dataDescription().spectralWindowId()(ddid);

  casacore::ROArrayColumn<casacore::Complex> dataCol(ms, "DATA");
  casacore::Array<casacore::Complex> arr = dataCol(row);

  // arr shape could be (nchan,ncorr) or (ncorr,nchan)
  if (arr.ndim() != 2) throw std::runtime_error("DATA row has unexpected ndim");
  const auto sh = arr.shape();
  int n0 = sh[0], n1 = sh[1];

  casacore::Matrix<casacore::Complex> mat;
  mat.assign(arr);

  // find corr axis
  if (n1 == 4) {
    if (chan < 0 || chan >= n0) throw std::runtime_error("chan out of range");
    for(int c=0;c<4;c++) out[c] = (std::complex<double>) mat(chan, c);
  } else if (n0 == 4) {
    if (chan < 0 || chan >= n1) throw std::runtime_error("chan out of range");
    for(int c=0;c<4;c++) out[c] = (std::complex<double>) mat(c, chan);
  } else {
    throw std::runtime_error("Cannot locate 4-corr axis in DATA row");
  }

  (void)spw;
}

int main(int argc, char** argv) {
  std::string ms_path;
  std::string obs_ms_path;
  std::string coeff_path;
  double src_ra_deg = 0.0;
  double src_dec_deg = 0.0;
  double flux_jy = 1.0;
  size_t row = 0;
  int chan = 0;

  for (int i=1;i<argc;i++) {
    if(std::strcmp(argv[i],"--ms")==0 && i+1<argc) ms_path = argv[++i];
    else if(std::strcmp(argv[i],"--obs-ms")==0 && i+1<argc) obs_ms_path = argv[++i];
    else if(std::strcmp(argv[i],"--beam")==0 && i+1<argc) coeff_path = argv[++i];
    else if(std::strcmp(argv[i],"--src-ra-deg")==0 && i+1<argc) src_ra_deg = std::atof(argv[++i]);
    else if(std::strcmp(argv[i],"--src-dec-deg")==0 && i+1<argc) src_dec_deg = std::atof(argv[++i]);
    else if(std::strcmp(argv[i],"--flux-jy")==0 && i+1<argc) flux_jy = std::atof(argv[++i]);
    else if(std::strcmp(argv[i],"--row")==0 && i+1<argc) row = (size_t) std::atoll(argv[++i]);
    else if(std::strcmp(argv[i],"--chan")==0 && i+1<argc) chan = std::atoi(argv[++i]);
    else if(std::strcmp(argv[i],"-h")==0 || std::strcmp(argv[i],"--help")==0) { usage(argv[0]); return 0; }
    else {
      std::cerr << "Unknown arg: " << argv[i] << "\n";
      usage(argv[0]);
      return 2;
    }
  }
  if(ms_path.empty() || coeff_path.empty()) { usage(argv[0]); return 2; }

  casacore::MeasurementSet ms(ms_path);
  casacore::MSColumns cols(ms);

  if(row >= (size_t) ms.nrow()) throw std::runtime_error("row out of range");

  const int ant1 = cols.antenna1()(row);
  const int ant2 = cols.antenna2()(row);
  const int fieldId = cols.fieldId()(row);
  const int ddid = cols.dataDescId()(row);
  const int spw = cols.dataDescription().spectralWindowId()(ddid);

  const casacore::Vector<double> uvw = cols.uvw()(row);
  const casacore::Vector<double> phasedir = get_phase_dir(ms, fieldId);
  const casacore::Vector<double> chanFreqs = get_chan_freqs(ms, spw);
  if(chan < 0 || chan >= (int)chanFreqs.size()) throw std::runtime_error("chan out of range for SPW");
  const double freq_hz = chanFreqs[chan];

  const double ra0 = phasedir[0];
  const double dec0 = phasedir[1];
  const double ra = deg2rad(src_ra_deg);
  const double dec = deg2rad(src_dec_deg);

  double l,m,n;
  radec_to_lmn(ra, dec, ra0, dec0, l, m, n);

  const std::complex<double> ph = phase_from_uvw(uvw, freq_hz, l, m, n);

  // EveryBeam Jones per antenna
  casacore::ScalarColumn<double> time_col(ms, "TIME");
  const double time0 = time_col(row);

  everybeam::Options options;
  options.coeff_path = coeff_path;
  options.beam_normalisation_mode = everybeam::BeamNormalisationMode::kFull;
  options.beam_mode = everybeam::BeamMode::kFull;
  options.frequency_interpolation = false;

  everybeam::telescope::MWA beam(ms, options);
  std::unique_ptr<everybeam::pointresponse::PointResponse> pr = beam.GetPointResponse(time0);

  std::complex<float> jp_f[4];
  std::complex<float> jq_f[4];
  pr->Response(everybeam::BeamMode::kFull, jp_f, ra, dec, freq_hz, ant1, 0);
  pr->Response(everybeam::BeamMode::kFull, jq_f, ra, dec, freq_hz, ant2, 0);

  // Convert to 2x2 complex<double>
  std::complex<double> Jp[2][2] = {{(std::complex<double>)jp_f[0], (std::complex<double>)jp_f[1]},
                                   {(std::complex<double>)jp_f[2], (std::complex<double>)jp_f[3]}};
  std::complex<double> Jq[2][2] = {{(std::complex<double>)jq_f[0], (std::complex<double>)jq_f[1]},
                                   {(std::complex<double>)jq_f[2], (std::complex<double>)jq_f[3]}};

  // Brightness matrix for unpolarized 1 Jy in linear basis so that XX=YY=I, XY=YX=0.
  const std::complex<double> B[2][2] = {{flux_jy, 0.0}, {0.0, flux_jy}};

  // Compute V = Jp * B * Jq^H * ph
  auto conjT = [](const std::complex<double> A[2][2], std::complex<double> out[2][2]) {
    out[0][0] = std::conj(A[0][0]);
    out[0][1] = std::conj(A[1][0]);
    out[1][0] = std::conj(A[0][1]);
    out[1][1] = std::conj(A[1][1]);
  };

  std::complex<double> JqH[2][2];
  conjT(Jq, JqH);

  std::complex<double> tmp[2][2];
  for(int i=0;i<2;i++) for(int j=0;j<2;j++) {
    tmp[i][j] = 0.0;
    for(int k=0;k<2;k++) tmp[i][j] += Jp[i][k] * B[k][j];
  }

  std::complex<double> Vmat[2][2];
  for(int i=0;i<2;i++) for(int j=0;j<2;j++) {
    Vmat[i][j] = 0.0;
    for(int k=0;k<2;k++) Vmat[i][j] += tmp[i][k] * JqH[k][j];
    Vmat[i][j] *= ph;
  }

  // Flatten to [XX,XY,YX,YY]
  std::complex<double> Vpred[4] = {Vmat[0][0], Vmat[0][1], Vmat[1][0], Vmat[1][1]};

  std::cerr << std::setprecision(12);
  std::cerr << "MS=" << ms_path << " row=" << row << " chan=" << chan << " freq_hz=" << freq_hz << "\n";
  std::cerr << "ant1=" << ant1 << " ant2=" << ant2 << " fieldId=" << fieldId << " spw=" << spw << "\n";
  std::cerr << "phase_dir(rad)=(" << ra0 << "," << dec0 << ") deg=(" << ra0*180/M_PI << "," << dec0*180/M_PI << ")\n";
  std::cerr << "src(rad)=(" << ra << "," << dec << ") deg=(" << src_ra_deg << "," << src_dec_deg << ")\n";
  std::cerr << "lmn=(" << l << "," << m << "," << n << ") ph=" << ph << "\n";
  std::cerr << "Jp=[" << Jp[0][0] << "," << Jp[0][1] << ";" << Jp[1][0] << "," << Jp[1][1] << "]\n";
  std::cerr << "Jq=[" << Jq[0][0] << "," << Jq[0][1] << ";" << Jq[1][0] << "," << Jq[1][1] << "]\n";

  print_vis4("Vpred", Vpred);

  std::complex<double> Vobs1[4];
  read_data_row_chan(ms_path, row, chan, Vobs1);
  print_vis4("Vobs(ms)", Vobs1);

  if(!obs_ms_path.empty()) {
    std::complex<double> Vobs2[4];
    read_data_row_chan(obs_ms_path, row, chan, Vobs2);
    print_vis4("Vobs(obs-ms)", Vobs2);
  }

  return 0;
}
