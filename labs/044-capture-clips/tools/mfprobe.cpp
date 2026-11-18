// Lab 044: opens a file the way Windows' own players do (Media Foundation's source reader) and says what they would
// see: duration, each stream's format, whether Windows can decode it, how many samples read cleanly and whether
// seeking to the middle works. Prints one JSON line.
//
//   mfprobe file.mp4

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <propvarutil.h>
#include <cstdio>
#include <string>
#include <vector>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "propsys.lib")
#pragma comment(lib, "ole32.lib")

static std::string subtypeName(const GUID& g)
{
    if (g == MFVideoFormat_H264) return "H264";
    if (g == MFVideoFormat_HEVC) return "HEVC";
    if (g == MFVideoFormat_AV1) return "AV1";
    if (g == MFAudioFormat_Opus) return "Opus";
    if (g == MFAudioFormat_AAC) return "AAC";
    char buf[64];
    snprintf(buf, sizeof(buf), "%08lx", g.Data1);
    return buf;
}

int wmain(int argc, wchar_t** argv)
{
    if (argc < 2) return 2;
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);
    IMFSourceReader* reader = nullptr;
    HRESULT hr = MFCreateSourceReaderFromURL(argv[1], nullptr, &reader);
    if (FAILED(hr)) {
        printf("{\"open\":false,\"hr\":\"%08lx\"}\n", hr);
        return 1;
    }
    PROPVARIANT var;
    PropVariantInit(&var);
    double durationS = -1;
    if (SUCCEEDED(reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &var))) {
        durationS = var.uhVal.QuadPart / 1e7;
    }
    PropVariantClear(&var);

    std::string streams;
    for (DWORD i = 0; i < 4; i++) {
        IMFMediaType* native = nullptr;
        if (FAILED(reader->GetNativeMediaType(i, 0, &native))) break;
        GUID major = {}, sub = {};
        native->GetGUID(MF_MT_MAJOR_TYPE, &major);
        native->GetGUID(MF_MT_SUBTYPE, &sub);
        UINT32 w = 0, h = 0;
        MFGetAttributeSize(native, MF_MT_FRAME_SIZE, &w, &h);
        native->Release();
        // Can Windows decode it? Ask for uncompressed output.
        IMFMediaType* out = nullptr;
        MFCreateMediaType(&out);
        out->SetGUID(MF_MT_MAJOR_TYPE, major);
        out->SetGUID(MF_MT_SUBTYPE, major == MFMediaType_Video ? MFVideoFormat_NV12 : MFAudioFormat_Float);
        HRESULT dec = reader->SetCurrentMediaType(i, nullptr, out);
        out->Release();
        reader->SetStreamSelection(i, TRUE);
        if (!streams.empty()) streams += ",";
        char buf[256];
        snprintf(buf, sizeof(buf), "{\"index\":%lu,\"kind\":\"%s\",\"codec\":\"%s\",\"width\":%u,\"height\":%u,\"decodable\":%s,\"hr\":\"%08lx\"",
                 i, major == MFMediaType_Video ? "video" : "audio", subtypeName(sub).c_str(), w, h, SUCCEEDED(dec) ? "true" : "false", dec);
        streams += buf;
        // Read every sample of this stream (decoded when decodable).
        int samples = 0, errors = 0;
        LONGLONG last = 0;
        for (DWORD j = 0; j < 4; j++) reader->SetStreamSelection(j, j == i);
        PROPVARIANT zero;
        InitPropVariantFromInt64(0, &zero);
        reader->SetCurrentPosition(GUID_NULL, zero);
        PropVariantClear(&zero);
        for (;;) {
            DWORD flags = 0, stream = 0;
            LONGLONG ts = 0;
            IMFSample* sample = nullptr;
            hr = reader->ReadSample(i, 0, &stream, &flags, &ts, &sample);
            if (FAILED(hr)) { errors++; break; }
            if (sample) { samples++; last = ts; sample->Release(); }
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
            if (flags & MF_SOURCE_READERF_ERROR) { errors++; break; }
        }
        // Seek to the middle and read one sample.
        bool seek = false;
        if (durationS > 0) {
            PROPVARIANT pos;
            InitPropVariantFromInt64((LONGLONG)(durationS * 1e7 / 2), &pos);
            if (SUCCEEDED(reader->SetCurrentPosition(GUID_NULL, pos))) {
                DWORD flags = 0, stream = 0;
                LONGLONG ts = 0;
                IMFSample* sample = nullptr;
                if (SUCCEEDED(reader->ReadSample(i, 0, &stream, &flags, &ts, &sample)) && sample) {
                    seek = true;
                    sample->Release();
                }
            }
            PropVariantClear(&pos);
        }
        snprintf(buf, sizeof(buf), ",\"samples\":%d,\"errors\":%d,\"lastS\":%.3f,\"seek\":%s}", samples, errors, last / 1e7, seek ? "true" : "false");
        streams += buf;
        for (DWORD j = 0; j < 4; j++) reader->SetStreamSelection(j, TRUE);
    }
    printf("{\"open\":true,\"durationS\":%.3f,\"streams\":[%s]}\n", durationS, streams.c_str());
    reader->Release();
    MFShutdown();
    return 0;
}
