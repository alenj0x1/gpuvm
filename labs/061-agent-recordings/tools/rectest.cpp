// Lab 061: feeds a real recording's video through the viewer's light recorder (transcoder.cpp) and its MP4 writer,
// frame by frame on the stream's own clock, as the viewer does while an agent works. Measures the cost (wall and CPU
// time of this process: the GPU's decoder plus Windows' H.264 encoder) and writes the file for ffprobe/SSIM/MF.
//
//   rectest --codec hevc --video in.hevc --times in.times [--fps 30] [--bitrate 2000000] [--realtime] --out out.mp4
//
// in.hevc / in.h264: Annex B with access unit delimiters (ffmpeg -bsf:v hevc_mp4toannexb,hevc_metadata=aud=insert);
// in.times: one presentation time in seconds per frame, in order (ffprobe -show_entries packet=pts_time).
// --realtime paces the frames at their own times (the viewer's case), else as fast as it can. Prints one JSON line.

// Built with the viewer's app\gpuvm folder on the include path (build.ps1 -Viewer).
#define NOMINMAX
#include "mp4writer.cpp"
#include "aacencoder.cpp"
#include "audiotrack.cpp"
#include "recordfile.cpp"
#include "transcoder.cpp"

#pragma comment(lib, "opus.lib")
#pragma comment(lib, "avcodec.lib")
#pragma comment(lib, "avutil.lib")

#include <chrono>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>

using namespace GpuVM;

static std::vector<uint8_t> readAll(const std::string& path)
{
    std::ifstream f(path, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

struct Frame {
    size_t at, size;
    bool key;
};

// Splits at access unit delimiters; a frame is key if it holds an IDR/IRAP slice.
static std::vector<Frame> frames(const std::vector<uint8_t>& s, bool h264)
{
    std::vector<size_t> starts;
    std::vector<Frame> out;
    for (size_t i = 0; i + 3 < s.size(); i++) {
        if (s[i] == 0 && s[i + 1] == 0 && s[i + 2] == 1) {
            int type = h264 ? (s[i + 3] & 0x1f) : ((s[i + 3] >> 1) & 0x3f);
            if (type == (h264 ? 9 : 35)) {
                starts.push_back(i > 0 && s[i - 1] == 0 ? i - 1 : i);
            }
            i += 2;
        }
    }
    starts.push_back(s.size());
    for (size_t k = 0; k + 1 < starts.size(); k++) {
        Frame f{ starts[k], starts[k + 1] - starts[k], false };
        for (size_t i = f.at; i + 3 < f.at + f.size; i++) {
            if (s[i] == 0 && s[i + 1] == 0 && s[i + 2] == 1) {
                int type = h264 ? (s[i + 3] & 0x1f) : ((s[i + 3] >> 1) & 0x3f);
                if (h264 ? type == 5 : (type >= 16 && type <= 21)) f.key = true;
                i += 2;
            }
        }
        out.push_back(f);
    }
    return out;
}

static double cpuSeconds()
{
    FILETIME c, e, k, u;
    GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
    auto s = [](FILETIME t) { return (double)(((uint64_t)t.dwHighDateTime << 32) | t.dwLowDateTime) / 1e7; };
    return s(k) + s(u);
}

int main(int argc, char** argv)
{
    std::string codec = "hevc", video, times, outPath;
    Transcoder::Settings settings;
    bool realtime = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
        if (a == "--codec") codec = next();
        else if (a == "--video") video = next();
        else if (a == "--times") times = next();
        else if (a == "--out") outPath = next();
        else if (a == "--fps") settings.fps = std::stoi(next());
        else if (a == "--bitrate") settings.bitrate = std::stoi(next());
        else if (a == "--key") settings.keySeconds = std::stoi(next());
        else if (a == "--quality") settings.quality = std::stoi(next());
        else if (a == "--realtime") realtime = true;
    }
    bool h264 = codec == "h264";
    std::vector<uint8_t> stream = readAll(video);
    std::vector<Frame> list = frames(stream, h264);
    std::vector<int64_t> at;
    {
        std::ifstream f(times);
        std::string line;
        while (std::getline(f, line)) {
            if (!line.empty() && line != "N/A") at.push_back((int64_t)(std::stod(line) * 1e6));
        }
    }
    if (list.empty() || at.size() < list.size()) {
        std::cout << "{\"ok\":false,\"error\":\"frames " << list.size() << " times " << at.size() << "\"}" << std::endl;
        return 1;
    }
    int width = 1920, height = 1080;
    Transcoder t;
    auto c0 = std::chrono::steady_clock::now();
    double cpu0 = cpuSeconds();
    if (!t.open(h264 ? VideoCodec::H264 : VideoCodec::HEVC, width, height, settings)) {
        std::cout << "{\"ok\":false,\"error\":\"open " << t.error() << "\"}" << std::endl;
        return 1;
    }
    Mp4VideoInfo info;
    info.codec = VideoCodec::H264;
    info.width = width;
    info.height = height;
    RecordFile file;
    std::wstring wout(outPath.begin(), outPath.end());
    _wremove(wout.c_str());
    if (!file.open(wout, info, nullptr)) {
        std::cout << "{\"ok\":false,\"error\":\"file\"}" << std::endl;
        return 1;
    }
    std::vector<EncodedFrame> out;
    bool ok = true;
    double worstMs = 0;
    int slow = 0;
    const int64_t first = at[0];
    for (size_t i = 0; i < list.size() && ok; i++) {
        int64_t rel = at[i] - first;
        if (realtime) {
            auto due = c0 + std::chrono::microseconds(rel);
            std::this_thread::sleep_until(due);
        }
        auto p0 = std::chrono::steady_clock::now();
        ok = t.push(stream.data() + list[i].at, list[i].size, rel, list[i].key, out);
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - p0).count();
        worstMs = std::max(worstMs, ms);
        if (ms > 1000.0 / 180) slow++;
        for (const EncodedFrame& f : out) {
            ok = ok && file.addVideo(f.data.data(), f.data.size(), f.timeUs, f.key);
        }
        out.clear();
    }
    t.drain(out);
    for (const EncodedFrame& f : out) {
        file.addVideo(f.data.data(), f.data.size(), f.timeUs, f.key);
    }
    bool closed = file.close();
    double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - c0).count();
    double cpu = cpuSeconds() - cpu0;
    double seconds = (at[list.size() - 1] - first) / 1e6;
    std::cout << "{\"ok\":" << (ok && closed ? "true" : "false") << ",\"frames\":" << list.size() << ",\"seconds\":" << seconds
              << ",\"wall_s\":" << wall << ",\"cpu_s\":" << cpu << ",\"cpu_per_video_s\":" << cpu / seconds
              << ",\"worst_push_ms\":" << worstMs << ",\"pushes_over_5_6ms\":" << slow
              << ",\"hw_decode\":" << (t.hardwareDecode() ? "true" : "false") << ",\"bytes\":" << t.counts().bytes
              << ",\"summary\":\"" << t.summary() << "\"}" << std::endl;
    return ok && closed ? 0 : 1;
}
