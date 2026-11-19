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

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

enum TimelineExport {

    /// Final Cut Pro / DaVinci Resolve: FCPXML 1.10, clips reference the original files.
    static func fcpxml(name: String, segments: [Segment], clips: [UUID: TimelineClip]) -> String? {
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

        var spine: [String] = []
        var offset = 0
        for seg in segments {
            guard let c = clips[seg.mediaID], let ref = assetIDs[seg.mediaID] else { continue }
            let dur = max(1, seq.frames(seg.length))
            let start = c.tcStart + c.rate.frames(seg.start)
            spine.append("""
                                <asset-clip ref="\(ref)" name="\(esc(c.media.name))" offset="\(seq.time(offset))" start="\(c.rate.time(start))" duration="\(seq.time(dur))" format="\(formatID(c))" tcFormat="NDF"/>
            """)
            offset += dur
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
    static func xmeml(name: String, segments: [Segment], clips: [UUID: TimelineClip]) -> String? {
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
        </audio>
        </media>
        </sequence>
        </xmeml>

        """
    }
}
