import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class TranscriptionSoundPlayer {
    static let shared = TranscriptionSoundPlayer()

    private var players: [String: AVAudioPlayer] = [:]
    private var savedSystemVolume: Float?

    private init() {}

    func playStartSound() {
        guard SettingsStore.shared.enableTranscriptionSounds else { return }
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(soundName: soundName)
    }

    func playStopSound() {
        guard SettingsStore.shared.enableTranscriptionSounds else { return }
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.stopSoundFileName else { return }
        self.play(soundName: soundName)
    }

    /// Preview a specific sound at the current volume setting (used in Settings UI).
    func playPreview(sound: SettingsStore.TranscriptionStartSound) {
        guard let soundName = sound.startSoundFileName else { return }
        self.play(soundName: soundName)
    }

    /// Preview current sound at a specific volume (used when slider is released).
    func playPreviewAtVolume(_ volume: Float) {
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(soundName: soundName, overrideVolume: volume)
    }

    private func play(soundName: String, overrideVolume: Float? = nil) {
        guard let url = Bundle.main.url(forResource: soundName, withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: \(soundName).m4a", source: "TranscriptionSoundPlayer")
            return
        }

        let settings = SettingsStore.shared
        let desiredVolume = overrideVolume ?? settings.transcriptionSoundVolume

        var playerVolume = desiredVolume
        var needsSystemVolumeBoost = false
        var systemVolumeBeforeBoost: Float = 1.0

        if settings.transcriptionSoundIndependentVolume {
            let currentSystemVol = Self.getSystemVolume()
            guard currentSystemVol > 0.001 else { return }
            // Perceived loudness is playerVolume x systemVolume. Whenever the
            // desired level fits under the current system volume, compensate
            // inside the player and leave the system volume alone - changing it
            // spikes any other audio that happens to be playing (issue #522).
            if desiredVolume <= currentSystemVol {
                playerVolume = desiredVolume / currentSystemVol
            } else {
                // Louder than the system volume allows: the system volume must be
                // raised, but only as far as needed and ramped smoothly so the
                // change never lands as a sudden spike.
                playerVolume = 1.0
                needsSystemVolumeBoost = true
                systemVolumeBeforeBoost = currentSystemVol
            }
        }

        do {
            let player: AVAudioPlayer
            if let existing = self.players[soundName] {
                player = existing
            } else {
                player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                self.players[soundName] = player
            }

            player.currentTime = 0
            player.volume = playerVolume

            if needsSystemVolumeBoost {
                // If a previous boost is still pending restore, keep its saved
                // (pre-boost) value so overlapping sounds never adopt a boosted
                // level as the volume to restore.
                self.savedSystemVolume = self.savedSystemVolume ?? systemVolumeBeforeBoost
                Self.rampSystemVolume(to: desiredVolume)
            }

            player.play()

            // Restore system volume after the sound finishes
            if needsSystemVolumeBoost {
                let duration = player.duration
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
                    guard let self, let saved = self.savedSystemVolume else { return }
                    Self.rampSystemVolume(to: saved)
                    self.savedSystemVolume = nil
                }
            }
        } catch {
            // Restore system volume on error
            if let saved = self.savedSystemVolume {
                Self.rampSystemVolume(to: saved)
                self.savedSystemVolume = nil
            }
            DebugLogger.shared.error(
                "Failed to play sound \(soundName).m4a: \(error.localizedDescription)",
                source: "TranscriptionSoundPlayer"
            )
        }
    }

    // MARK: - System Volume via CoreAudio

    /// Moves the system output volume to `target` in small steps instead of a
    /// single jump, so any other audio playing changes level smoothly rather
    /// than spiking (issue #522).
    private nonisolated static func rampSystemVolume(
        to target: Float,
        duration: TimeInterval = 0.12,
        steps: Int = 8
    ) {
        let start = self.getSystemVolume()
        guard abs(start - target) > 0.001 else { return }

        let stepDelayMicros = useconds_t((duration / Double(steps)) * 1_000_000)
        DispatchQueue.global(qos: .userInteractive).async {
            for step in 1...steps {
                let fraction = Float(step) / Float(steps)
                self.setSystemVolume(start + (target - start) * fraction)
                if step < steps {
                    usleep(stepDelayMicros)
                }
            }
        }
    }

    private nonisolated static func getDefaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    nonisolated static func getSystemVolume() -> Float {
        guard let deviceID = getDefaultOutputDeviceID() else { return 1.0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return 1.0 }
        return volume
    }

    private nonisolated static func setSystemVolume(_ volume: Float) {
        guard let deviceID = getDefaultOutputDeviceID() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        if status != noErr {
            DebugLogger.shared.error("Failed to set system volume: OSStatus \(status)", source: "TranscriptionSoundPlayer")
        }
    }
}
