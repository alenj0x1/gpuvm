// Lab 044: feeds an elementary stream (and Opus packets) through the viewer's own MP4 writer, the way the viewer
// does while recording, so the files can be checked with ffprobe and Media Foundation without a VM.
//
//   mp4test --codec hevc --video in.hevc --fps 60 [--opus in.ogg] [--start 37] [--drop 50] --out out.mp4
//
// in.hevc / in.h264: Annex B with access unit delimiters (one frame each); in.obu: AV1 low overhead OBUs (one
// temporal unit per temporal delimiter). --start skips the first frames (a recording that begins mid-stream);
// --drop removes every Nth frame (lost packets). Prints one JSON line.

// Built with the viewer's app\gpuvm folder on the include path (build.ps1 -Viewer).
#include "mp4writer.cpp"
#include "aacencoder.cpp"
#include "audiotrack.cpp"
#include "recordfile.cpp"

#pragma comment(lib, "opus.lib")

#include <chrono>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

using namespace GpuVM;

static std::vector<uint8_t> readAll(const std::string& path)
{
    std::ifstream f(path, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

struct Frame {
    std::vector<uint8_t> data;
    bool key;
};

static std::vector<Frame> annexBFrames(const std::vector<uint8_t>& s, bool h264)
{
    std::vector<Frame> out;
    std::vector<size_t> starts;
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
        Frame f;
        f.data.assign(s.begin() + starts[k], s.begin() + starts[k + 1]);
        f.key = false;
        for (size_t i = 0; i + 3 < f.data.size(); i++) {
            if (f.data[i] == 0 && f.data[i + 1] == 0 && f.data[i + 2] == 1) {
                int type = h264 ? (f.data[i + 3] & 0x1f) : ((f.data[i + 3] >> 1) & 0x3f);
                if (h264 ? type == 5 : (type >= 16 && type <= 21)) f.key = true;
                i += 2;
            }
        }
        out.push_back(std::move(f));
    }
    return out;
}

static std::vector<Frame> obuFrames(const std::vector<uint8_t>& s)
{
    std::vector<Frame> out;
    size_t i = 0;
    while (i < s.size()) {
        uint8_t h = s[i];
        int type = (h >> 3) & 0xf;
        size_t hs = ((h >> 2) & 1) ? 2 : 1, used = 0;
        size_t n = (size_t)readLeb128(s.data() + i + hs, s.size() - i - hs, &used);
        if (type == 2 || out.empty()) out.push_back({ {}, false });
        if (type == 1) out.back().key = true;  // a sequence header comes with each key frame from encoders
        out.back().data.insert(out.back().data.end(), s.begin() + i, s.begin() + i + hs + used + n);
        i += hs + used + n;
    }
    return out;
}

static std::vector<std::vector<uint8_t>> oggPackets(const std::vector<uint8_t>& s)
{
    std::vector<std::vector<uint8_t>> out;
    std::vector<uint8_t> cur;
    size_t i = 0;
    while (i + 27 <= s.size() && memcmp(&s[i], "OggS", 4) == 0) {
        int segs = s[i + 26];
        size_t body = i + 27 + segs;
        for (int k = 0; k < segs; k++) {
            int len = s[i + 27 + k];
            cur.insert(cur.end(), s.begin() + body, s.begin() + body + len);
            body += len;
            if (len < 255) {
                out.push_back(cur);
                cur.clear();
            }
        }
        i = body;
    }
    if (out.size() >= 2) out.erase(out.begin(), out.begin() + 2);  // OpusHead, OpusTags
    return out;
}

int main(int argc, char** argv)
{
    std::string codec = "hevc", video, opus, outPath, audioCodec = "aac";
    // A live stream's clock doesn't start at zero (the host's presentation time since the session began).
    long long offsetUs = 0;
    // Packets stamped by arrival, as the viewer does live: up to this much late, at random.
    int jitterUs = 0;
    long long muteFromMs = -1, muteToMs = -1;
    unsigned rng = 12345;
    int fps = 60, start = 0, drop = 0, spp = 240, primaries = 1, transfer = 1, matrix = 1, width = 1920, height = 1080;
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string k = argv[i], v = argv[i + 1];
        if (k == "--codec") codec = v;
        else if (k == "--video") video = v;
        else if (k == "--opus") opus = v;
        else if (k == "--out") outPath = v;
        else if (k == "--fps") fps = std::stoi(v);
        else if (k == "--start") start = std::stoi(v);
        else if (k == "--drop") drop = std::stoi(v);
        else if (k == "--spp") spp = std::stoi(v);
        else if (k == "--width") width = std::stoi(v);
        else if (k == "--height") height = std::stoi(v);
        else if (k == "--hdr" && v == "1") { primaries = 9; transfer = 16; matrix = 9; }
        else if (k == "--audio") audioCodec = v;
        else if (k == "--offset") offsetUs = std::stoll(v);
        else if (k == "--jitter") jitterUs = std::stoi(v);
        else if (k == "--mute-from") muteFromMs = std::stoll(v);
        else if (k == "--mute-to") muteToMs = std::stoll(v);
    }
    std::vector<uint8_t> raw = readAll(video);
    std::vector<Frame> frames = codec == "av1" ? obuFrames(raw) : annexBFrames(raw, codec == "h264");
    std::vector<std::vector<uint8_t>> packets;
    if (!opus.empty()) packets = oggPackets(readAll(opus));

    Mp4VideoInfo vi;
    vi.codec = codec == "h264" ? VideoCodec::H264 : codec == "av1" ? VideoCodec::AV1 : VideoCodec::HEVC;
    vi.width = width;
    vi.height = height;
    vi.primaries = primaries;
    vi.transfer = transfer;
    vi.matrix = matrix;
    Mp4AudioInfo ai;
    ai.samplesPerPacket = spp;

    // The same path as the viewer (RecordFile: Opus decoded and encoded as AAC, silence where no sound came), or the
    // Opus packets as they are (--audio opus, the first lab's comparison).
    bool aac = audioCodec == "aac";
    std::wstring wpath(outPath.begin(), outPath.end());
    RecordFile rec;
    Mp4Writer plain;
    bool opened = aac ? rec.open(wpath, vi, packets.empty() ? nullptr : &ai) : plain.open(wpath, vi, packets.empty() ? nullptr : &ai);
    if (!opened) {
        std::cout << "{\"ok\":false,\"error\":\"open\"}" << std::endl;
        return 1;
    }
    // Interleaved by time, as they arrive live. --mute-from/--mute-to (ms): the machine sends no sound then.
    auto t0 = std::chrono::steady_clock::now();
    size_t a = 0;
    int written = 0, keys = 0;
    for (size_t f = 0; f < frames.size(); f++) {
        int64_t vt = (int64_t)f * 1000000 / fps;
        while (a < packets.size() && (int64_t)a * spp * 1000000 / 48000 <= vt) {
            int64_t at = (int64_t)a * spp * 1000000 / 48000;
            rng = rng * 1103515245 + 12345;
            int64_t late = jitterUs > 0 ? (int64_t)((rng >> 8) % (unsigned)jitterUs) : 0;
            bool muted = at >= muteFromMs * 1000 && at < muteToMs * 1000;
            if (!muted) {
                if (aac) rec.addAudio(packets[a].data(), packets[a].size(), at + offsetUs + late);
                else plain.addAudio(packets[a].data(), packets[a].size(), at + offsetUs + late);
            }
            a++;
        }
        vt += offsetUs;
        if ((int)f < start || (drop > 0 && f % drop == (size_t)drop - 1 && !frames[f].key)) continue;
        if (aac) rec.addVideo(frames[f].data.data(), frames[f].data.size(), vt, frames[f].key);
        else plain.addVideo(frames[f].data.data(), frames[f].data.size(), vt, frames[f].key);
        written++;
        keys += frames[f].key;
    }
    bool ok = aac ? rec.close() : plain.close();
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    std::cout << "{\"ok\":" << (ok ? "true" : "false") << ",\"error\":\"" << (aac ? rec.error() : plain.error()) << "\",\"frames\":" << frames.size()
              << ",\"written\":" << written << ",\"keys\":" << keys << ",\"audioPackets\":" << packets.size()
              << ",\"durationMs\":" << (aac ? rec.durationMs() : plain.durationMs()) << ",\"writeMs\":" << ms
              << ",\"sound\":\"" << (aac ? rec.summary() : std::string("opus")) << "\"}" << std::endl;
    return ok ? 0 : 1;
}
