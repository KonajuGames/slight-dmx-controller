#include "song_features.h"

#include "decode.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <utility>
#include <vector>

using namespace godot;

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kTau = 6.28318530717958647692;
constexpr int kOnsetDecim = 128;    // must match SongAnalyzer.ONSET_DECIM
constexpr double kWorkRate = 11025.0; // target analysis rate (== 44100 / 4)

// --- iterative radix-2 FFT, a direct port of fft.gd -------------------
void fft_transform(std::vector<double> &re, std::vector<double> &im, int n) {
	int j = 0;
	for (int i = 1; i < n; i++) {
		int bit = n >> 1;
		for (; j & bit; bit >>= 1) {
			j ^= bit;
		}
		j ^= bit;
		if (i < j) {
			std::swap(re[i], re[j]);
			std::swap(im[i], im[j]);
		}
	}
	for (int seg = 2; seg <= n; seg <<= 1) {
		double ang = -kTau / seg;
		double wr = std::cos(ang);
		double wi = std::sin(ang);
		int half = seg >> 1;
		for (int i = 0; i < n; i += seg) {
			double cr = 1.0, ci = 0.0;
			for (int k = 0; k < half; k++) {
				int a = i + k;
				int b = a + half;
				double tr = cr * re[b] - ci * im[b];
				double ti = cr * im[b] + ci * re[b];
				re[b] = re[a] - tr;
				im[b] = im[a] - ti;
				re[a] += tr;
				im[a] += ti;
				double ncr = cr * wr - ci * wi;
				ci = cr * wi + ci * wr;
				cr = ncr;
			}
		}
	}
}

void normalise01(std::vector<float> &a) {
	float lo = INFINITY, hi = -INFINITY;
	for (float v : a) {
		lo = v < lo ? v : lo;
		hi = v > hi ? v : hi;
	}
	float span = hi - lo;
	if (span < 1e-6f) {
		return;
	}
	for (float &v : a) {
		v = (v - lo) / span;
	}
}

// Hann-windowed-sinc anti-aliasing decimation by an integer factor.
std::vector<float> hann_decimate(const float *in, int64_t n_in, int factor) {
	if (factor <= 1) {
		return std::vector<float>(in, in + n_in);
	}
	int R = 2 * factor;
	double fc = 0.45 / factor; // cutoff, cycles/sample, safely under 0.5/factor
	std::vector<double> k(2 * R + 1);
	double ksum = 0.0;
	for (int i = -R; i <= R; i++) {
		double s = (i == 0) ? 2.0 * fc : std::sin(2.0 * kPi * fc * i) / (kPi * i);
		double win = 0.5 - 0.5 * std::cos(2.0 * kPi * (i + R) / (2.0 * R));
		k[i + R] = s * win;
		ksum += s * win;
	}
	for (double &v : k) {
		v /= ksum;
	}
	int64_t n_out = n_in / factor;
	std::vector<float> out(n_out);
	for (int64_t m = 0; m < n_out; m++) {
		int64_t center = m * factor;
		double acc = 0.0;
		for (int j = -R; j <= R; j++) {
			int64_t idx = center + j;
			idx = idx < 0 ? 0 : (idx >= n_in ? n_in - 1 : idx);
			acc += k[j + R] * in[idx];
		}
		out[m] = static_cast<float>(acc);
	}
	return out;
}

Dictionary fail(const String &msg) {
	Dictionary d;
	d["ok"] = false;
	d["error"] = msg;
	return d;
}

PackedFloat32Array to_pfa(const std::vector<float> &v) {
	PackedFloat32Array a;
	a.resize(static_cast<int64_t>(v.size()));
	if (!v.empty()) {
		std::memcpy(a.ptrw(), v.data(), v.size() * sizeof(float));
	}
	return a;
}

// Extensions with no bundled decoder, handed to the OS's (dec_os.cpp).
bool is_os_format(const String &ext) {
	return ext == "m4a" || ext == "aac" || ext == "mp4";
}

// Stream-decode any supported file into `sink`. Returns the decoder's
// result (0, SD_STOPPED or < 0); on failure `err` says why.
int stream_file(const String &path, sd_sink sink, void *ctx, String &err) {
	String ext = path.get_extension().to_lower();
	if (is_os_format(ext)) {
		CharString p = ProjectSettings::get_singleton()->globalize_path(path).utf8();
		int rc = sd_stream_os(p.get_data(), sink, ctx);
		if (rc == SD_NO_OS_DECODER) {
			err = "no ." + ext + " decoder on this system";
		} else if (rc < 0) {
			err = "couldn't decode the audio (" + String::num_int64(rc) + ")";
		}
		return rc;
	}
	// The compressed file is small; only the decoded PCM is streamed.
	PackedByteArray bytes = FileAccess::get_file_as_bytes(path);
	if (bytes.is_empty()) {
		err = "can't read " + path;
		return -1;
	}
	int rc;
	if (ext == "mp3") {
		rc = sd_stream_mp3(bytes.ptr(), static_cast<size_t>(bytes.size()), sink, ctx);
	} else if (ext == "ogg" || ext == "oga") {
		rc = sd_stream_ogg(bytes.ptr(), static_cast<size_t>(bytes.size()), sink, ctx);
	} else if (ext == "wav") {
		rc = sd_stream_wav(bytes.ptr(), static_cast<size_t>(bytes.size()), sink, ctx);
	} else {
		err = "unsupported file type ." + ext;
		return -2;
	}
	if (rc < 0) {
		err = "couldn't decode the audio (" + String::num_int64(rc) + ")";
	}
	return rc;
}

// --- whole-PCM collection (analyze_file on OS-decoded formats) -------
struct PcmCollect {
	std::vector<float> pcm;
	int channels = 0;
	int rate = 0;
	double max_seconds = 0.0;
	bool too_long = false;
	std::atomic<bool> *cancel = nullptr;
};

int collect_sink(void *ctx, const float *pcm, int64_t frames, int channels, int rate, int64_t) {
	PcmCollect *c = static_cast<PcmCollect *>(ctx);
	if (c->cancel->load()) {
		return 1;
	}
	if (c->channels == 0) {
		c->channels = channels;
		c->rate = rate;
	}
	if (channels != c->channels) {
		return 0; // a mid-stream format change: drop it rather than garble
	}
	c->pcm.insert(c->pcm.end(), pcm, pcm + frames * channels);
	// Stop before a long mix fills memory, not after.
	if (static_cast<double>(c->pcm.size()) / channels / rate > c->max_seconds) {
		c->too_long = true;
		return 1;
	}
	return 0;
}

// --- streaming waveform envelope (waveform_file) ----------------------
// Per column: RMS loudness, and RMS of three bands split with two one-pole
// filters -- bass below ~250 Hz, air above ~2.5 kHz, mid between -- the
// same bands the STFT version uses, but cheap enough to run per sample.
struct WaveAcc {
	std::atomic<bool> *cancel = nullptr;
	std::atomic<float> *progress = nullptr;
	int cps = 100;
	int rate = 0;
	int channels = 0;
	double a_lo = 0.0, a_hi = 0.0, lp1 = 0.0, lp2 = 0.0;
	double s_all = 0.0, s_lo = 0.0, s_mid = 0.0, s_hi = 0.0;
	int64_t n = 0;           // samples in the current column
	int64_t frame = 0;       // samples so far
	int64_t col_end = 0;     // sample index where the current column ends
	std::vector<float> lo, mid, hi, pk;

	void flush() {
		double inv = n > 0 ? 1.0 / n : 0.0;
		pk.push_back(static_cast<float>(std::sqrt(s_all * inv)));
		lo.push_back(static_cast<float>(std::sqrt(s_lo * inv)));
		mid.push_back(static_cast<float>(std::sqrt(s_mid * inv)));
		hi.push_back(static_cast<float>(std::sqrt(s_hi * inv)));
		s_all = s_lo = s_mid = s_hi = 0.0;
		n = 0;
		col_end = static_cast<int64_t>(std::llround(static_cast<double>(pk.size() + 1) * rate / cps));
	}
};

int wave_sink(void *ctx, const float *pcm, int64_t frames, int channels, int rate, int64_t total) {
	WaveAcc *a = static_cast<WaveAcc *>(ctx);
	if (a->cancel->load()) {
		return 1;
	}
	if (a->rate == 0) {
		a->rate = rate;
		a->channels = channels;
		a->a_lo = 1.0 - std::exp(-kTau * 250.0 / rate);
		a->a_hi = 1.0 - std::exp(-kTau * 2500.0 / rate);
		a->col_end = static_cast<int64_t>(std::llround(static_cast<double>(rate) / a->cps));
	}
	if (channels != a->channels) {
		return 0; // see collect_sink
	}
	const double inv_ch = 1.0 / channels;
	for (int64_t i = 0; i < frames; i++) {
		double x = 0.0;
		const float *f = pcm + i * channels;
		for (int c = 0; c < channels; c++) {
			x += f[c];
		}
		x *= inv_ch;
		a->lp1 += a->a_lo * (x - a->lp1);
		a->lp2 += a->a_hi * (x - a->lp2);
		double l = a->lp1, m = a->lp2 - a->lp1, h = x - a->lp2;
		a->s_all += x * x;
		a->s_lo += l * l;
		a->s_mid += m * m;
		a->s_hi += h * h;
		a->n++;
		if (++a->frame >= a->col_end) {
			a->flush();
		}
	}
	if (total > 0) {
		float p = static_cast<float>(static_cast<double>(a->frame) / total);
		a->progress->store(p < 0.99f ? p : 0.99f);
	}
	return 0;
}

} // namespace

void SongFeatures::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("analyze_file", "path", "n_fft", "hop", "wave_cols"),
			&SongFeatures::analyze_file);
	ClassDB::bind_method(D_METHOD("get_progress"), &SongFeatures::get_progress);
	ClassDB::bind_method(D_METHOD("waveform_file", "path", "cols_per_sec"), &SongFeatures::waveform_file);
	ClassDB::bind_method(D_METHOD("cancel"), &SongFeatures::cancel);
	ClassDB::bind_static_method("SongFeatures", D_METHOD("os_decoder_available"),
			&SongFeatures::os_decoder_available);
}

void SongFeatures::cancel() {
	_cancel.store(true);
}

bool SongFeatures::os_decoder_available() {
	return sd_os_decoder_available() != 0;
}

Dictionary SongFeatures::waveform_file(const String &path, int cols_per_sec) {
	_progress.store(0.0f);
	_cancel.store(false);
	WaveAcc acc;
	acc.cancel = &_cancel;
	acc.progress = &_progress;
	acc.cps = cols_per_sec < 1 ? 1 : (cols_per_sec > 1000 ? 1000 : cols_per_sec);

	String err;
	int rc = stream_file(path, &wave_sink, &acc, err);
	if (rc == SD_STOPPED) {
		return fail("cancelled");
	}
	if (rc < 0) {
		return fail(err);
	}
	if (acc.n > 0) {
		acc.flush();
	}
	if (acc.rate < 1 || acc.pk.empty()) {
		return fail("no audio in the file");
	}

	float pk_max = 1e-9f, band_max = 1e-9f;
	for (size_t i = 0; i < acc.pk.size(); i++) {
		pk_max = acc.pk[i] > pk_max ? acc.pk[i] : pk_max;
		float b = acc.lo[i] > acc.mid[i] ? acc.lo[i] : acc.mid[i];
		b = acc.hi[i] > b ? acc.hi[i] : b;
		band_max = b > band_max ? b : band_max;
	}
	for (size_t i = 0; i < acc.pk.size(); i++) {
		acc.pk[i] /= pk_max;
		acc.lo[i] /= band_max;
		acc.mid[i] /= band_max;
		acc.hi[i] /= band_max;
	}

	Dictionary d;
	d["ok"] = true;
	d["duration"] = static_cast<double>(acc.frame) / acc.rate;
	d["cols_per_sec"] = acc.cps;
	d["wave_lo"] = to_pfa(acc.lo);
	d["wave_mid"] = to_pfa(acc.mid);
	d["wave_hi"] = to_pfa(acc.hi);
	d["wave_peak"] = to_pfa(acc.pk);
	_progress.store(1.0f);
	return d;
}

SongFeatures::SongFeatures() {}
SongFeatures::~SongFeatures() {}

float SongFeatures::get_progress() const {
	return _progress.load();
}

Dictionary SongFeatures::analyze_file(const String &path, int n_fft, int hop, int wave_cols) {
	_progress.store(0.0f);

	if (n_fft < 256 || (n_fft & (n_fft - 1)) != 0 || hop < 1 || wave_cols < 16) {
		return fail("bad analysis parameters");
	}

	constexpr double kMaxSeconds = 3600.0;
	String ext = path.get_extension().to_lower();
	sd_audio au;
	std::memset(&au, 0, sizeof(au));
	// OS-decoded formats are collected here (and stopped at the length cap
	// while decoding); the bundled decoders malloc their own buffer.
	std::vector<float> os_pcm;
	auto release_pcm = [&]() {
		if (os_pcm.empty()) {
			sd_audio_free(&au);
		} else {
			os_pcm.clear();
			os_pcm.shrink_to_fit();
			au.pcm = nullptr;
		}
	};

	if (is_os_format(ext)) {
		_cancel.store(false);
		PcmCollect col;
		col.cancel = &_cancel;
		col.max_seconds = kMaxSeconds;
		String err;
		int rc = stream_file(path, &collect_sink, &col, err);
		if (col.too_long) {
			return fail("track is too long");
		}
		if (rc == SD_STOPPED) {
			return fail("cancelled");
		}
		if (rc < 0) {
			return fail(err);
		}
		if (col.channels < 1 || col.rate < 1 || col.pcm.empty()) {
			return fail("no audio in the file");
		}
		os_pcm.swap(col.pcm);
		au.pcm = os_pcm.data();
		au.channels = col.channels;
		au.rate = col.rate;
		au.frames = static_cast<int64_t>(os_pcm.size()) / col.channels;
	} else {
		PackedByteArray bytes = FileAccess::get_file_as_bytes(path);
		if (bytes.is_empty()) {
			return fail("can't read " + path);
		}
		const uint8_t *raw = bytes.ptr();
		size_t raw_n = static_cast<size_t>(bytes.size());
		int rc;
		if (ext == "mp3") {
			rc = sd_decode_mp3(raw, raw_n, &au);
		} else if (ext == "ogg" || ext == "oga") {
			rc = sd_decode_ogg(raw, raw_n, &au);
		} else if (ext == "wav") {
			rc = sd_decode_wav(raw, raw_n, &au);
		} else {
			return fail("unsupported file type ." + ext);
		}
		if (rc != 0 || !au.pcm || au.frames < 1 || au.channels < 1 || au.rate < 1) {
			sd_audio_free(&au);
			return fail("couldn't decode the audio (" + String::num_int64(rc) + ")");
		}
	}

	const int64_t frames_native = au.frames;
	const int rate_native = au.rate;
	const double duration = static_cast<double>(frames_native) / rate_native;

	if (duration < 5.0) {
		release_pcm();
		return fail("track is too short");
	}
	if (duration > kMaxSeconds) {
		release_pcm();
		return fail("track is too long");
	}
	_progress.store(0.28f);

	// --- downmix to mono ------------------------------------------------
	std::vector<float> mono(frames_native);
	{
		const int C = au.channels;
		const float *s = au.pcm;
		if (C == 1) {
			std::memcpy(mono.data(), s, frames_native * sizeof(float));
		} else {
			const double inv = 1.0 / C;
			for (int64_t i = 0; i < frames_native; i++) {
				double acc = 0.0;
				const float *f = s + i * C;
				for (int c = 0; c < C; c++) {
					acc += f[c];
				}
				mono[i] = static_cast<float>(acc * inv);
			}
		}
	}
	release_pcm();

	// --- decimate to the working rate --------------------------------
	int factor = static_cast<int>(std::lround(rate_native / kWorkRate));
	if (factor < 1) {
		factor = 1;
	}
	const double work_rate = static_cast<double>(rate_native) / factor;
	std::vector<float> w = hann_decimate(mono.data(), frames_native, factor);
	mono.clear();
	mono.shrink_to_fit();
	_progress.store(0.35f);

	const int64_t L = static_cast<int64_t>(w.size());
	if (L < static_cast<int64_t>(work_rate * 3.0)) {
		return fail("not enough audio after decode");
	}

	// --- STFT (port of SongAnalyzer._stft, speed == 1) ---------------
	const int half = n_fft / 2 + 1;
	std::vector<int> bin_pc(half), bin_band(half);
	for (int k = 0; k < half; k++) {
		double f = static_cast<double>(k) * work_rate / n_fft;
		if (f < 55.0 || f > 2000.0) {
			bin_pc[k] = -1;
		} else {
			int midi = static_cast<int>(std::floor(69.0 + 12.0 * std::log2(f / 440.0) + 0.5));
			bin_pc[k] = ((midi % 12) + 12) % 12;
		}
		bin_band[k] = f < 250.0 ? 0 : (f < 2500.0 ? 1 : 2);
	}

	int64_t nframes = (L - n_fft) / hop;
	if (nframes < 1) {
		nframes = 1;
	}

	std::vector<float> chroma(static_cast<size_t>(nframes) * 12, 0.0f);
	std::vector<float> rms(nframes), centroid(nframes), flux(nframes);
	std::vector<float> blo(nframes), bmid(nframes), bhi(nframes);

	std::vector<double> re(n_fft), im(n_fft);
	std::vector<float> win(n_fft);
	{
		double invn = 1.0 / (n_fft - 1);
		for (int i = 0; i < n_fft; i++) {
			win[i] = static_cast<float>(0.5 - 0.5 * std::cos(kTau * i * invn));
		}
	}
	std::vector<float> prev(half, 0.0f);
	bool have_prev = false;

	for (int64_t fr = 0; fr < nframes; fr++) {
		int64_t off = fr * hop;
		for (int i = 0; i < n_fft; i++) {
			int64_t idx = off + i;
			double s = (idx >= 0 && idx < L) ? w[idx] : 0.0;
			re[i] = s * win[i];
			im[i] = 0.0;
		}
		fft_transform(re, im, n_fft);

		double e = 0.0, cnum = 0.0, cden = 0.0, fx = 0.0;
		double eb[3] = { 0.0, 0.0, 0.0 };
		float *crow = &chroma[static_cast<size_t>(fr) * 12];
		for (int k = 0; k < half; k++) {
			double m = std::sqrt(re[k] * re[k] + im[k] * im[k]);
			e += m * m;
			cnum += k * m;
			cden += m;
			eb[bin_band[k]] += m * m;
			int pc = bin_pc[k];
			if (pc >= 0) {
				crow[pc] += static_cast<float>(m);
			}
			if (have_prev) {
				double d = m - prev[k];
				if (d > 0.0) {
					fx += d;
				}
			}
			prev[k] = static_cast<float>(m);
		}
		have_prev = true;

		double cs = 0.0;
		for (int i = 0; i < 12; i++) {
			cs += crow[i];
		}
		if (cs > 0.0001) {
			for (int i = 0; i < 12; i++) {
				crow[i] /= static_cast<float>(cs);
			}
		}
		rms[fr] = static_cast<float>(std::sqrt(e / half));
		centroid[fr] = static_cast<float>(cden > 0.0 ? cnum / cden : 0.0);
		flux[fr] = static_cast<float>(fx);
		blo[fr] = static_cast<float>(std::sqrt(eb[0]));
		bmid[fr] = static_cast<float>(std::sqrt(eb[1]));
		bhi[fr] = static_cast<float>(std::sqrt(eb[2]));

		if ((fr & 63) == 0) {
			_progress.store(0.35f + 0.53f * static_cast<float>(fr) / nframes);
		}
	}
	_progress.store(0.88f);

	// --- onset envelope (port of SongAnalyzer._onset_env) ------------
	int64_t out_n = L / kOnsetDecim;
	std::vector<float> olo(out_n, 0.0f), ohi(out_n, 0.0f);
	{
		double lp = 0.0, hp_prev = 0.0, x_prev = 0.0, acc_lo = 0.0, acc_hi = 0.0;
		int cnt = 0;
		int64_t oi = 0;
		for (int64_t i = 0; i < L; i++) {
			double x = w[i];
			lp += 0.15 * (x - lp);
			double h = 0.85 * (hp_prev + x - x_prev);
			hp_prev = h;
			x_prev = x;
			acc_lo += lp * lp;
			acc_hi += h * h;
			if (++cnt >= kOnsetDecim) {
				if (oi < out_n) {
					olo[oi] = static_cast<float>(std::sqrt(acc_lo / cnt));
					ohi[oi] = static_cast<float>(std::sqrt(acc_hi / cnt));
				}
				oi++;
				acc_lo = 0.0;
				acc_hi = 0.0;
				cnt = 0;
			}
		}
	}
	normalise01(olo);
	normalise01(ohi);
	std::vector<float> env(out_n, 0.0f);
	for (int64_t i = 1; i < out_n; i++) {
		float dl = olo[i] - olo[i - 1];
		float dh = ohi[i] - ohi[i - 1];
		env[i] = (dl > 0.0f ? dl : 0.0f) + 0.35f * (dh > 0.0f ? dh : 0.0f);
	}
	std::vector<float> onset(out_n, 0.0f);
	for (int64_t i = 0; i < out_n; i++) {
		double s = 0.0;
		int cw = 0;
		for (int64_t jj = (i > 0 ? i - 1 : 0); jj < (i + 2 < out_n ? i + 2 : out_n); jj++) {
			s += env[jj];
			cw++;
		}
		onset[i] = static_cast<float>(cw > 0 ? s / cw : 0.0);
	}
	_progress.store(0.95f);

	// --- whole-song waveform envelope (port of _build_wave) ----------
	std::vector<float> wl(wave_cols), wm(wave_cols), wh(wave_cols), wp(wave_cols);
	{
		int64_t nf = nframes;
		double pk_max = 1e-9, bnd_max = 1e-9;
		for (int c = 0; c < wave_cols; c++) {
			int64_t f0 = static_cast<int64_t>(c) * nf / wave_cols;
			int64_t f1 = (static_cast<int64_t>(c) + 1) * nf / wave_cols;
			if (f1 < f0 + 1) {
				f1 = f0 + 1;
			}
			int64_t fe = f1 < nf ? f1 : nf;
			double sl = 0.0, sm = 0.0, sh = 0.0, pk = 0.0;
			for (int64_t i = f0; i < fe; i++) {
				sl += blo[i];
				sm += bmid[i];
				sh += bhi[i];
				if (rms[i] > pk) {
					pk = rms[i];
				}
			}
			double dn = static_cast<double>((fe - f0) > 1 ? (fe - f0) : 1);
			sl /= dn;
			sm /= dn;
			sh /= dn;
			wl[c] = static_cast<float>(sl);
			wm[c] = static_cast<float>(sm);
			wh[c] = static_cast<float>(sh);
			wp[c] = static_cast<float>(pk);
			pk_max = pk > pk_max ? pk : pk_max;
			double bm = sl > sm ? (sl > sh ? sl : sh) : (sm > sh ? sm : sh);
			bnd_max = bm > bnd_max ? bm : bnd_max;
		}
		for (int c = 0; c < wave_cols; c++) {
			wl[c] = static_cast<float>(wl[c] / bnd_max);
			wm[c] = static_cast<float>(wm[c] / bnd_max);
			wh[c] = static_cast<float>(wh[c] / bnd_max);
			wp[c] = static_cast<float>(wp[c] / pk_max);
		}
	}

	Dictionary d;
	d["ok"] = true;
	d["rate"] = work_rate;
	d["duration"] = duration;
	d["nframes"] = static_cast<int64_t>(nframes);
	d["chroma"] = to_pfa(chroma);
	d["rms"] = to_pfa(rms);
	d["centroid"] = to_pfa(centroid);
	d["flux"] = to_pfa(flux);
	d["onset"] = to_pfa(onset);
	d["onset_hz"] = work_rate / kOnsetDecim;
	d["wave_lo"] = to_pfa(wl);
	d["wave_mid"] = to_pfa(wm);
	d["wave_hi"] = to_pfa(wh);
	d["wave_peak"] = to_pfa(wp);
	_progress.store(1.0f);
	return d;
}
