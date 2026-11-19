import AVFoundation
import Foundation

/// Frame rate as an exact rational frame duration (num/den seconds), the way NLE XML wants it.
struct FrameRate: Hashable {
    let num: Int
    let den: Int

    init(fps: Double) {
        let r = max(1, Int(fps.rounded()))
        if abs(fps - Double(r)) > 0.01 {        // 23.976, 29.97, 59.94 …
            num = 1001; den = r * 1000
        } else {
            num = 100; den = r * 100
        }
    }

    var timebase: Int { Int((Double(den) / Double(num)).rounded()) }
    var ntsc: Bool { num == 1001 }

    func frames(_ seconds: Double) -> Int { Int((seconds * Double(den) / Double(num)).rounded()) }
    /// FCPXML rational time string for a frame count.
    func time(_ frames: Int) -> String { frames == 0 ? "0s" : "\(frames * num)/\(den)s" }

    func timecode(_ frames: Int) -> String {
        let tb = timebase
        let f = max(frames, 0)
        return String(format: "%02d:%02d:%02d:%02d", f / tb / 3600, (f / tb / 60) % 60, (f / tb) % 60, f % tb)
    }
}

/// Everything the XML needs to know about one source file.
struct TimelineClip {
    let media: MediaClip
    let rate: FrameRate
    let tcStart: Int          // source timecode at frame 0, in frames
    let hasAudio: Bool
    let audioChannels: Int
    let audioRate: Int
    var frames: Int { rate.frames(media.duration) }
    var width: Int { Int(media.displaySize.width.rounded()) }
    var height: Int { Int(media.displaySize.height.rounded()) }

    static func gather(_ m: MediaClip) async -> TimelineClip {
        var channels = 2, sampleRate = 48_000
        if let a = m.audioTrack,
           let fd = try? await a.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            channels = max(1, Int(asbd.mChannelsPerFrame))
            sampleRate = Int(asbd.mSampleRate)
        }
        return TimelineClip(media: m, rate: FrameRate(fps: m.fps),
                            tcStart: await timecodeStart(m.asset) ?? 0,
                            hasAudio: m.audioTrack != nil, audioChannels: channels, audioRate: sampleRate)
    }

    /// First frame number of the file's timecode track (cameras often start at 01:00:00:00).
    private static func timecodeStart(_ asset: AVAsset) async -> Int? {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        // The reader may hand back empty marker buffers first; take the first one that carries data.
        var found: (CMBlockBuffer, CMFormatDescription)?
        for _ in 0..<16 {
            guard let sb = out.copyNextSampleBuffer() else { break }
            if let b = CMSampleBufferGetDataBuffer(sb), let f = CMSampleBufferGetFormatDescription(sb) {
                found = (b, f); break
            }
        }
        guard let (block, fd) = found else { return nil }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr else { return nil }
        switch CMFormatDescriptionGetMediaSubType(fd) {
        case kCMTimeCodeFormatType_TimeCode32 where bytes.count >= 4:
            return Int(bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case kCMTimeCodeFormatType_TimeCode64 where bytes.count >= 8:
            return Int(bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        default:
            return nil
        }
    }
}

/// A sound-reel clip with what the XML needs to know about its audio file.
struct TimelineMusic {
    let clip: MusicClip
    let source: AudioSource
    let channels: Int
    let sampleRate: Int

    static func gather(_ music: [MusicClip], sources: [UUID: AudioSource]) async -> [TimelineMusic] {
        var out: [TimelineMusic] = []
        for c in music {
            guard let s = sources[c.sourceID] else { continue }
            var ch = 2, sr = 48_000
            if let fd = try? await s.track.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                ch = max(1, Int(asbd.mChannelsPerFrame)); sr = Int(asbd.mSampleRate)
            }
            out.append(TimelineMusic(clip: c, source: s, channels: ch, sampleRate: sr))
        }
        return out
    }

    var gainDB: String {
        clip.gain <= 0.0001 ? "-96dB" : String(format: "%.1fdB", 20 * log10(clip.gain))
    }
}

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

enum TimelineExport {

    /// Final Cut Pro / DaVinci Resolve: FCPXML 1.10, clips reference the original files.
    static func fcpxml(name: String, segments: [Segment], clips: [UUID: TimelineClip], music: [TimelineMusic] = []) -> String? {
        guard let first = segments.first.flatMap({ clips[$0.mediaID] }) else { return nil }
        let seq = first.rate
        var resources: [String] = []
        var nextID = 0
        func newID() -> String { nextID += 1; return "r\(nextID)" }

        var formatIDs: [String: String] = [:]
        func formatID(_ c: TimelineClip) -> String {
            let key = "\(c.width)x\(c.height)@\(c.rate.num)/\(c.rate.den)"
            if let id = formatIDs[key] { return id }
            let id = newID()
            formatIDs[key] = id
            resources.append("""
                    <format id="\(id)" frameDuration="\(c.rate.time(1))" width="\(c.width)" height="\(c.height)"/>
            """)
            return id
        }
        let seqFormat = formatID(first)

        var assetIDs: [UUID: String] = [:]
        for seg in segments where assetIDs[seg.mediaID] == nil {
            guard let c = clips[seg.mediaID] else { continue }
            let fmt = formatID(c)
            let id = newID()
            assetIDs[seg.mediaID] = id
            let audio = c.hasAudio
                ? #" hasAudio="1" audioSources="1" audioChannels="\#(c.audioChannels)" audioRate="\#(c.audioRate)""#
                : ""
            resources.append("""
                    <asset id="\(id)" name="\(esc(c.media.name))" start="\(c.rate.time(c.tcStart))" duration="\(c.rate.time(c.frames))" hasVideo="1" format="\(fmt)" videoSources="1"\(audio)>
                        <media-rep kind="original-media" src="\(esc(c.media.url.absoluteString))"/>
                    </asset>
            """)
        }

        // audio-only assets for the sound reel
        var musicAssetIDs: [UUID: String] = [:]
        for m in music where musicAssetIDs[m.source.id] == nil {
            let id = newID()
            musicAssetIDs[m.source.id] = id
            resources.append("""
                    <asset id="\(id)" name="\(esc(m.source.name))" start="0s" duration="\(seq.time(seq.frames(m.source.duration)))" hasAudio="1" audioSources="1" audioChannels="\(m.channels)" audioRate="\(m.sampleRate)">
                        <media-rep kind="original-media" src="\(esc(m.source.url.absoluteString))"/>
                    </asset>
            """)
        }

        // lay out the picture first, so each music clip can be connected to the clip it starts under
        struct Placed { let ref: String; let c: TimelineClip; let offset: Int; let dur: Int; let start: Int }
        var placed: [Placed] = []
        var offset = 0
        for seg in segments {
            guard let c = clips[seg.mediaID], let ref = assetIDs[seg.mediaID] else { continue }
            let dur = max(1, seq.frames(seg.length))
            placed.append(Placed(ref: ref, c: c, offset: offset, dur: dur, start: c.tcStart + c.rate.frames(seg.start)))
            offset += dur
        }
        let total = offset

        var spine: [String] = []
        for (i, pl) in placed.enumerated() {
            // music whose head falls inside this picture clip hangs below it (lane -1), as connected clips
            var connected: [String] = []
            for m in music {
                let at = seq.frames(m.clip.at)
                guard at >= pl.offset, at < pl.offset + pl.dur || (i == placed.count - 1 && at < total),
                      let ref = musicAssetIDs[m.source.id] else { continue }
                let len = min(seq.frames(m.clip.length), total - at)
                guard len > 0 else { continue }
                // a connected clip's offset is in its parent's own (source) timeline
                let localOffset = pl.c.rate.time(pl.start + pl.c.rate.frames(Double(at - pl.offset) * Double(seq.num) / Double(seq.den)))
                var fades = ""
                if m.clip.fadeIn > 0 || m.clip.fadeOut > 0 {
                    fades = "<param name=\"amount\">"
                        + (m.clip.fadeIn > 0 ? "<fadeIn type=\"easeIn\" duration=\"\(seq.time(max(1, seq.frames(m.clip.fadeIn))))\"/>" : "")
                        + (m.clip.fadeOut > 0 ? "<fadeOut type=\"easeIn\" duration=\"\(seq.time(max(1, seq.frames(m.clip.fadeOut))))\"/>" : "")
                        + "</param>"
                }
                connected.append("""
                                    <asset-clip ref="\(ref)" lane="-1" name="\(esc(m.source.name))" offset="\(localOffset)" start="\(seq.time(seq.frames(m.clip.start)))" duration="\(seq.time(len))" audioRole="music"><adjust-volume amount="\(m.gainDB)">\(fades)</adjust-volume></asset-clip>
                """)
            }
            let head = #"<asset-clip ref="\#(pl.ref)" name="\#(esc(pl.c.media.name))" offset="\#(seq.time(pl.offset))" start="\#(pl.c.rate.time(pl.start))" duration="\#(seq.time(pl.dur))" format="\#(formatID(pl.c))" tcFormat="NDF""#
            if connected.isEmpty {
                spine.append("                    " + head + "/>")
            } else {
                spine.append("                    " + head + ">\n" + connected.joined(separator: "\n") + "\n                    </asset-clip>")
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
            <resources>
        \(resources.joined(separator: "\n"))
            </resources>
            <library>
                <event name="MakeFilm">
                    <project name="\(esc(name))">
                        <sequence format="\(seqFormat)" duration="\(seq.time(offset))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
        \(spine.joined(separator: "\n"))
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>

        """
    }

    /// Premiere Pro (and Resolve): Final Cut Pro 7 XML ("xmeml").
    static func xmeml(name: String, segments: [Segment], clips: [UUID: TimelineClip], music: [TimelineMusic] = []) -> String? {
        guard let first = segments.first.flatMap({ clips[$0.mediaID] }) else { return nil }
        let seq = first.rate
        func rate(_ r: FrameRate) -> String {
            "<rate><timebase>\(r.timebase)</timebase><ntsc>\(r.ntsc ? "TRUE" : "FALSE")</ntsc></rate>"
        }

        var fileIDs: [UUID: String] = [:]
        func fileElement(_ c: TimelineClip) -> String {
            if let id = fileIDs[c.media.id] { return "<file id=\"\(id)\"/>" }
            let id = "file-\(fileIDs.count + 1)"
            fileIDs[c.media.id] = id
            let path = c.media.url.absoluteString.replacingOccurrences(of: "file://", with: "file://localhost")
            let audio = c.hasAudio ? """
            <audio><samplecharacteristics><depth>16</depth><samplerate>\(c.audioRate)</samplerate></samplecharacteristics><channelcount>\(c.audioChannels)</channelcount></audio>
            """ : ""
            return """
            <file id="\(id)">
                <name>\(esc(c.media.name))</name>
                <pathurl>\(esc(path))</pathurl>
                \(rate(c.rate))
                <duration>\(c.frames)</duration>
                <timecode>\(rate(c.rate))<string>\(c.rate.timecode(c.tcStart))</string><frame>\(c.tcStart)</frame><displayformat>NDF</displayformat></timecode>
                <media>
                    <video><samplecharacteristics>\(rate(c.rate))<width>\(c.width)</width><height>\(c.height)</height><pixelaspectratio>square</pixelaspectratio></samplecharacteristics></video>
                    \(audio)
                </media>
            </file>
            """
        }

        var videoItems: [String] = [], audioItems: [String] = []
        var offset = 0
        for (i, seg) in segments.enumerated() {
            guard let c = clips[seg.mediaID] else { continue }
            let dur = max(1, seq.frames(seg.length))
            let inF = c.rate.frames(seg.start)
            let outF = inF + max(1, c.rate.frames(seg.length))
            let vID = "clipitem-v\(i + 1)", aID = "clipitem-a\(i + 1)"
            let links = c.hasAudio ? """
            <link><linkclipref>\(vID)</linkclipref><mediatype>video</mediatype><trackindex>1</trackindex><clipindex>\(i + 1)</clipindex></link>
            <link><linkclipref>\(aID)</linkclipref><mediatype>audio</mediatype><trackindex>1</trackindex><clipindex>\(i + 1)</clipindex></link>
            """ : ""
            let common = """
            <name>\(esc(c.media.name))</name>
            <enabled>TRUE</enabled>
            <duration>\(c.frames)</duration>
            \(rate(c.rate))
            <start>\(offset)</start><end>\(offset + dur)</end>
            <in>\(inF)</in><out>\(outF)</out>
            """
            videoItems.append("""
            <clipitem id="\(vID)">
            \(common)
            \(fileElement(c))
            \(links)
            </clipitem>
            """)
            if c.hasAudio {
                audioItems.append("""
                <clipitem id="\(aID)">
                \(common)
                \(fileElement(c))
                <sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>
                \(links)
                </clipitem>
                """)
            }
            offset += dur
        }

        // the sound reel as its own audio track, with its level
        var musicItems: [String] = []
        var musicFileIDs: [UUID: String] = [:]
        for (i, m) in music.enumerated() {
            let at = seq.frames(m.clip.at)
            let len = min(seq.frames(m.clip.length), offset - at)
            guard at < offset, len > 0 else { continue }
            let inF = seq.frames(m.clip.start)
            let fileXML: String
            if let id = musicFileIDs[m.source.id] {
                fileXML = "<file id=\"\(id)\"/>"
            } else {
                let id = "file-music-\(musicFileIDs.count + 1)"
                musicFileIDs[m.source.id] = id
                let path = m.source.url.absoluteString.replacingOccurrences(of: "file://", with: "file://localhost")
                fileXML = """
                <file id="\(id)"><name>\(esc(m.source.name))</name><pathurl>\(esc(path))</pathurl>\(rate(seq))<duration>\(seq.frames(m.source.duration))</duration><media><audio><samplecharacteristics><depth>16</depth><samplerate>\(m.sampleRate)</samplerate></samplecharacteristics><channelcount>\(m.channels)</channelcount></audio></media></file>
                """
            }
            musicItems.append("""
            <clipitem id="clipitem-m\(i + 1)">
            <name>\(esc(m.source.name))</name>
            <enabled>TRUE</enabled>
            <duration>\(seq.frames(m.source.duration))</duration>
            \(rate(seq))
            <start>\(at)</start><end>\(at + len)</end>
            <in>\(inF)</in><out>\(inF + len)</out>
            \(fileXML)
            <sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>
            <filter><effect><name>Audio Levels</name><effectid>audiolevels</effectid><effectcategory>audiolevels</effectcategory><effecttype>audiolevels</effecttype><mediatype>audio</mediatype><parameter><parameterid>level</parameterid><name>Level</name><valuemin>0</valuemin><valuemax>3.98109</valuemax><value>\(String(format: "%.5f", m.clip.gain))</value></parameter></effect></filter>
            </clipitem>
            """)
        }
        let musicTrack = musicItems.isEmpty ? "" : "<track>\n" + musicItems.joined(separator: "\n") + "\n</track>"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4">
        <sequence id="sequence-1">
        <name>\(esc(name))</name>
        <duration>\(offset)</duration>
        \(rate(seq))
        <timecode>\(rate(seq))<string>00:00:00:00</string><frame>0</frame><displayformat>NDF</displayformat></timecode>
        <media>
        <video>
        <format><samplecharacteristics>\(rate(seq))<width>\(first.width)</width><height>\(first.height)</height><pixelaspectratio>square</pixelaspectratio></samplecharacteristics></format>
        <track>
        \(videoItems.joined(separator: "\n"))
        </track>
        </video>
        <audio>
        <numOutputChannels>2</numOutputChannels>
        <format><samplecharacteristics><depth>16</depth><samplerate>48000</samplerate></samplecharacteristics></format>
        <track>
        \(audioItems.joined(separator: "\n"))
        </track>
        \(musicTrack)
        </audio>
        </media>
        </sequence>
        </xmeml>

        """
    }
}
