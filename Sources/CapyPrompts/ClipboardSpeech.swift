import AppKit
import AVFoundation

@MainActor
final class ClipboardSpeech: NSObject, AVAudioPlayerDelegate {
    var onStatus: ((String) -> Void)?

    private enum State {
        case idle, preparing, playing, paused, finished, failed
    }

    private struct Narration {
        let id = UUID()
        var parts: [String] = []
        let voice: String
        var audio: [Int: Data] = [:]
    }

    private let service = AliyunSpeech()
    private let diagnostics = getenv("CAPY_SPEECH_DIAGNOSTICS").map { String(cString: $0) } == "1"
    private func trace(_ event: String) {
        guard diagnostics else { return }
        FileHandle.standardError.write(Data(("speech " + event + "\n").utf8))
    }
    private var narration: Narration?
    private var index = 0
    private var state = State.idle
    private var lastStatus: String?
    private var request: Task<Void, Never>?
    private var player: AVAudioPlayer?

    func toggle() {
        switch state {
        case .idle, .finished, .failed:
            readNew()
        case .preparing, .playing:
            player?.pause()
            update(.paused, "已暂停")
        case .paused:
            continuePart()
        }
    }

    func readNew() {
        discardPlayback()
        index = 0
        narration = nil
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update(.idle, "剪贴板没有可朗读的文本")
            return
        }
        do {
            let voice = try AliyunSpeech.selectedVoice()
            let snapshot = Narration(voice: voice)
            narration = snapshot
            update(.preparing, "正在整理朗读稿")
            request = Task { [weak self] in
                do {
                    let script = try await Generator().speechScript(for: text)
                    try Task.checkCancellation()
                    guard let self, self.narration?.id == snapshot.id else { return }
                    self.request = nil
                    let parts = AliyunSpeech.chunks(script)
                    guard !parts.isEmpty else {
                        self.narration = nil
                        self.update(.finished, "没有需要朗读的正文")
                        return
                    }
                    self.narration?.parts = parts
                    self.trace("script ready chars=\(script.count) parts=\(parts.count)")
                    if self.state == .preparing { self.continuePart() }
                } catch {
                    guard !Task.isCancelled, let self, self.narration?.id == snapshot.id else { return }
                    self.request = nil
                    self.narration = nil
                    self.update(.failed, "朗读稿整理失败：" + error.localizedDescription)
                }
            }
        } catch {
            update(.failed, "无法读取朗读音色")
        }
    }

    func restart() {
        guard narration != nil else {
            readNew()
            return
        }
        if narration?.parts.isEmpty == true, request != nil {
            update(.preparing, "正在整理朗读稿")
            return
        }
        discardPlayback()
        index = 0
        continuePart()
    }

    func stop() {
        discardPlayback()
        index = 0
        if narration?.parts.isEmpty == true { narration = nil }
        update(.idle, "已停止")
    }

    private func discardPlayback() {
        request?.cancel()
        request = nil
        player?.delegate = nil
        player?.stop()
        player = nil
    }

    private func continuePart() {
        guard let narration else { return }
        if narration.parts.isEmpty { update(.preparing, "正在整理朗读稿"); return }
        if let player {
            start(player)
            return
        }
        if let data = narration.audio[index] {
            do {
                let player = try AVAudioPlayer(data: data)
                self.player = player
                player.delegate = self
                start(player)
            } catch {
                update(.failed, "无法解码朗读音频")
            }
            return
        }
        if request == nil {
            let text = narration.parts[index]
            let voice = narration.voice
            request = Task { [weak self, service] in
                do {
                    let data = try await service.synthesize(text, voice: voice)
                    guard !Task.isCancelled, let self else { return }
                    self.request = nil
                    self.narration?.audio[self.index] = data
                    if self.diagnostics {
                        self.trace("audio part=\(self.index + 1) bytes=\(data.count)")
                    }
                    if self.state == .preparing { self.continuePart() }
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.request = nil
                    self.update(.failed, error.localizedDescription)
                }
            }
        }
        update(.preparing, "正在缓冲")
    }

    private func start(_ player: AVAudioPlayer) {
        if player.play() {
            update(.playing, "正在朗读")
        } else {
            discardPlayback()
            update(.failed, "无法播放朗读音频")
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.endPart(player, successfully: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.endPart(player, successfully: false) }
    }

    private func endPart(_ finishedPlayer: AVAudioPlayer, successfully: Bool) {
        guard player === finishedPlayer, let count = narration?.parts.count else { return }
        finishedPlayer.delegate = nil
        player = nil
        guard successfully else {
            update(.failed, "朗读音频播放失败")
            return
        }
        guard index + 1 < count else {
            update(.finished, "朗读完毕")
            return
        }
        index += 1
        if state == .paused {
            update(.paused, "已暂停")
        } else {
            continuePart()
        }
    }

    private func update(_ newState: State, _ message: String) {
        state = newState
        let status: String
        if let narration, !narration.parts.isEmpty, [.preparing, .playing, .paused].contains(newState) {
            status = "\(message) (\(index + 1)/\(narration.parts.count))"
        } else {
            status = message
        }
        if diagnostics {
            let position = Int((player?.currentTime ?? 0) * 1000)
            let voice = narration?.voice ?? "-"
            trace("\(message) part=\(index + 1) positionMs=\(position) voice=\(voice) session=\(narration?.id.uuidString ?? "-")")
        }
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus?(status)
    }
}
