// The OS's own audio decoder, for formats with no bundled decoder -- AAC
// (.m4a / .aac / .mp4) above all, which is most of a typical iTunes /
// VirtualDJ library:
//   - Windows: Media Foundation's source reader. mfplat.dll / mfreadwrite.dll
//     are loaded at run time: Windows "N" editions ship without them unless
//     the Media Feature Pack is installed, and linking them would stop the
//     whole extension loading there.
//   - macOS: AudioToolbox's ExtAudioFile (always present).
//   - elsewhere: no OS decoder (SD_NO_OS_DECODER).
// Both decode to 32-bit float at the file's own rate and channel count.

#include "decode.h"

#include <string.h>

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
// Define Media Foundation's GUIDs in this translation unit rather than
// linking mfuuid.lib.
#include <initguid.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <string>
#include <vector>

namespace {

typedef HRESULT(WINAPI *MFStartupFn)(ULONG version, DWORD flags);
typedef HRESULT(WINAPI *MFShutdownFn)();
typedef HRESULT(WINAPI *MFCreateMediaTypeFn)(IMFMediaType **type);
typedef HRESULT(WINAPI *MFCreateSourceReaderFromURLFn)(LPCWSTR url, IMFAttributes *attrs,
		IMFSourceReader **reader);

struct Mf {
	bool tried = false;
	MFStartupFn startup = nullptr;
	MFShutdownFn shutdown = nullptr;
	MFCreateMediaTypeFn create_media_type = nullptr;
	MFCreateSourceReaderFromURLFn create_reader = nullptr;

	bool load() {
		if (!tried) {
			tried = true;
			HMODULE plat = LoadLibraryW(L"mfplat.dll");
			HMODULE rw = LoadLibraryW(L"mfreadwrite.dll");
			if (plat && rw) {
				startup = (MFStartupFn)GetProcAddress(plat, "MFStartup");
				shutdown = (MFShutdownFn)GetProcAddress(plat, "MFShutdown");
				create_media_type = (MFCreateMediaTypeFn)GetProcAddress(plat, "MFCreateMediaType");
				create_reader = (MFCreateSourceReaderFromURLFn)GetProcAddress(rw, "MFCreateSourceReaderFromURL");
			}
			// The DLLs stay loaded for the life of the process.
		}
		return startup && shutdown && create_media_type && create_reader;
	}
};

Mf g_mf;
// load() is idempotent but not thread-safe; decodes run on worker threads.
SRWLOCK g_mf_lock = SRWLOCK_INIT;

bool mf_loaded() {
	AcquireSRWLockExclusive(&g_mf_lock);
	bool ok = g_mf.load();
	ReleaseSRWLockExclusive(&g_mf_lock);
	return ok;
}

template <typename T>
void release(T *&p) {
	if (p) {
		p->Release();
		p = nullptr;
	}
}

std::wstring widen_path(const char *utf8) {
	int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
	if (n <= 0) {
		return std::wstring();
	}
	std::wstring w(n - 1, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &w[0], n);
	for (auto &c : w) {
		if (c == L'/') {
			c = L'\\';
		}
	}
	return w;
}

// Ask the reader for float PCM and read back what it settled on.
bool configure(IMFSourceReader *reader, int *channels, int *rate) {
	IMFMediaType *want = nullptr;
	if (FAILED(g_mf.create_media_type(&want))) {
		return false;
	}
	want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
	want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
	HRESULT hr = reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, want);
	release(want);
	if (FAILED(hr)) {
		return false;
	}
	IMFMediaType *got = nullptr;
	if (FAILED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, &got))) {
		return false;
	}
	UINT32 ch = 0, hz = 0;
	got->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch);
	got->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &hz);
	release(got);
	*channels = (int)ch;
	*rate = (int)hz;
	return ch > 0 && hz > 0;
}

int decode_mf(const char *path_utf8, sd_sink sink, void *ctx) {
	if (!mf_loaded()) {
		return SD_NO_OS_DECODER;
	}
	// Media Foundation needs COM on this thread; any apartment will do.
	HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	bool co_owned = SUCCEEDED(co);
	if (FAILED(g_mf.startup(MF_VERSION, MFSTARTUP_LITE))) {
		if (co_owned) {
			CoUninitialize();
		}
		return -10;
	}

	int rc = 0;
	IMFSourceReader *reader = nullptr;
	std::wstring wpath = widen_path(path_utf8);
	if (FAILED(g_mf.create_reader(wpath.c_str(), nullptr, &reader))) {
		rc = -11; // missing file, or no decoder for it
	} else {
		reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
		reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
		int ch = 0, rate = 0;
		if (!configure(reader, &ch, &rate)) {
			rc = -12; // no audio stream, or not decodable to float
		} else {
			int64_t total = 0;
			PROPVARIANT dur;
			PropVariantInit(&dur);
			if (SUCCEEDED(reader->GetPresentationAttribute((DWORD)MF_SOURCE_READER_MEDIASOURCE,
						MF_PD_DURATION, &dur))) {
				// 100-ns units
				total = (int64_t)((double)dur.uhVal.QuadPart * 1e-7 * rate);
			}
			PropVariantClear(&dur);

			for (;;) {
				DWORD flags = 0;
				IMFSample *sample = nullptr;
				if (FAILED(reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, nullptr,
							&flags, nullptr, &sample))) {
					rc = -13;
					break;
				}
				if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
					if (!configure(reader, &ch, &rate)) {
						release(sample);
						rc = -12;
						break;
					}
				}
				if (sample) {
					IMFMediaBuffer *buf = nullptr;
					if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buf))) {
						BYTE *data = nullptr;
						DWORD len = 0;
						if (SUCCEEDED(buf->Lock(&data, nullptr, &len))) {
							int64_t frames = (int64_t)(len / (sizeof(float) * (DWORD)ch));
							int stop = frames > 0
									? sink(ctx, (const float *)data, frames, ch, rate, total)
									: 0;
							buf->Unlock();
							if (stop) {
								rc = SD_STOPPED;
							}
						}
						release(buf);
					}
					release(sample);
					if (rc != 0) {
						break;
					}
				}
				if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
					break;
				}
			}
		}
		release(reader);
	}
	g_mf.shutdown();
	if (co_owned) {
		CoUninitialize();
	}
	return rc;
}

} // namespace

extern "C" int sd_stream_os(const char *path_utf8, sd_sink sink, void *ctx) {
	return decode_mf(path_utf8, sink, ctx);
}

extern "C" int sd_os_decoder_available(void) {
	return mf_loaded() ? 1 : 0;
}

#elif defined(__APPLE__)

#include <AudioToolbox/AudioToolbox.h>

#include <vector>

extern "C" int sd_stream_os(const char *path_utf8, sd_sink sink, void *ctx) {
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8 *)path_utf8,
			(CFIndex)strlen(path_utf8), false);
	if (!url) {
		return -11;
	}
	ExtAudioFileRef file = nullptr;
	OSStatus st = ExtAudioFileOpenURL(url, &file);
	CFRelease(url);
	if (st != noErr || !file) {
		return -11;
	}
	AudioStreamBasicDescription in = {};
	UInt32 sz = sizeof(in);
	st = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &sz, &in);
	int ch = (int)in.mChannelsPerFrame;
	int rate = (int)in.mSampleRate;
	if (st != noErr || ch < 1 || rate < 1) {
		ExtAudioFileDispose(file);
		return -12;
	}
	AudioStreamBasicDescription out = {};
	out.mSampleRate = in.mSampleRate;
	out.mFormatID = kAudioFormatLinearPCM;
	out.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
	out.mChannelsPerFrame = (UInt32)ch;
	out.mBitsPerChannel = 32;
	out.mBytesPerFrame = (UInt32)(4 * ch);
	out.mFramesPerPacket = 1;
	out.mBytesPerPacket = out.mBytesPerFrame;
	if (ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(out), &out) != noErr) {
		ExtAudioFileDispose(file);
		return -12;
	}
	SInt64 total = 0;
	sz = sizeof(total);
	ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &sz, &total);

	const UInt32 chunk = 8192;
	std::vector<float> buf((size_t)chunk * ch);
	int rc = 0;
	for (;;) {
		AudioBufferList abl;
		abl.mNumberBuffers = 1;
		abl.mBuffers[0].mNumberChannels = (UInt32)ch;
		abl.mBuffers[0].mDataByteSize = (UInt32)(buf.size() * sizeof(float));
		abl.mBuffers[0].mData = buf.data();
		UInt32 frames = chunk;
		if (ExtAudioFileRead(file, &frames, &abl) != noErr) {
			rc = -13;
			break;
		}
		if (frames == 0) {
			break;
		}
		if (sink(ctx, buf.data(), (int64_t)frames, ch, rate, (int64_t)total) != 0) {
			rc = SD_STOPPED;
			break;
		}
	}
	ExtAudioFileDispose(file);
	return rc;
}

extern "C" int sd_os_decoder_available(void) {
	return 1;
}

#else

extern "C" int sd_stream_os(const char *, sd_sink, void *) {
	return SD_NO_OS_DECODER;
}

extern "C" int sd_os_decoder_available(void) {
	return 0;
}

#endif
