import AVFoundation
import CoreAudio

/// Records everything the Mac plays (the other people on the call) through a Core Audio
/// process tap. Same mechanism Granola uses on current macOS; needs the
/// "System Audio Recording" permission, not Screen Recording.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pendingRestart: DispatchWorkItem?
    private let queue = DispatchQueue(label: "callrecorder.system-audio", qos: .userInitiated)

    func start(writingTo url: URL) throws {
        writer = TrackWriter(file: try makeWavFile(at: url, sampleRate: 48_000, channels: 2))
        try startDevice()
    }

    func stop() {
        pendingRestart?.cancel()
        pendingRestart = nil
        stopDevice()
        writer = nil
    }

    private func startDevice() throws {
        guard let writer else { return }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Call Recorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        // The aggregate is clocked by the output device active right now, so it is rebuilt
        // whenever that device changes or changes format (see listenForDeviceChanges).
        let outputID = try Self.defaultOutputDevice()
        let outputUID = try Self.uid(of: outputID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Call Recorder Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the aggregate device")

        var streamDescription = try tapFormat()
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RecorderError(message: "Unsupported system audio format")
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            writer.write(buffer)
        }, "attach to the aggregate device")
        try check(AudioDeviceStart(aggregateID, ioProcID), "start system audio capture")
        listenForDeviceChanges(outputID: outputID)
    }

    private func stopDevice() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        // Let the last buffer finish writing before the file closes.
        queue.sync {}
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// AirPods connecting, or switching to call mode when a mic opens, changes the default
    /// output or its sample rate. The old aggregate then goes silent, so rebuild it.
    private func listenForDeviceChanges(outputID: AudioObjectID) {
        let watched: [(AudioObjectID, AudioObjectPropertySelector)] = [
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
            (outputID, kAudioDevicePropertyNominalSampleRate),
            (outputID, kAudioDevicePropertyDeviceIsAlive),
            (tapID, kAudioTapPropertyFormat),
        ]
        for (object, selector) in watched {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleRestart()
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }

    /// Several properties change together during one switch; restart once they settle.
    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.writer != nil else { return }
            NSLog("Output device changed, rebuilding system audio capture")
            self.stopDevice()
            do {
                try self.startDevice()
            } catch {
                NSLog("System audio restart failed: \(error)")
                self.stopDevice()
                self.scheduleRestart()
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read the tap format")
        return format
    }

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            "find the output device"
        )
        return deviceID
    }

    private static func uid(of deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "read the output device ID")
        guard let uid else { throw RecorderError(message: "Output device has no ID") }
        return uid.takeRetainedValue() as String
    }
}
