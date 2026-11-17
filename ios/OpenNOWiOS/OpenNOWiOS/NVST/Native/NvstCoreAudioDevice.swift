import AudioToolbox
import AVFAudio
import Foundation

public struct NvstCaptureDeviceChange: Equatable, Sendable {
    public let resolvedUniqueID: String?
    public let preferredUniqueID: String?
    public let isFallback: Bool
}

public final class NvstCoreAudioDevice: @unchecked Sendable {
    public var fillPlayout: (@Sendable (UnsafeMutablePointer<Int16>, Int) -> Void)?
    public var onGameAudio: (@Sendable (UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    public var onMicrophoneAudio: (@Sendable (UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    public var onMicrophoneLevel: (@Sendable (Double) -> Void)?
    public var isMicrophoneCaptureEnabled: (@Sendable () -> Bool)?
    public var onCaptureDeviceChange: (@Sendable (NvstCaptureDeviceChange) -> Void)?
    public var onInputDeviceListChange: (@Sendable () -> Void)?
    private let muteLock = NSLock()
    private var playoutMuted = false
    public var isPlayoutMuted: Bool {
        get { muteLock.lock(); defer { muteLock.unlock() }; return playoutMuted }
        set { muteLock.lock(); playoutMuted = newValue; muteLock.unlock() }
    }
    public private(set) var isPlayoutRunning = false
    public private(set) var isCaptureRunning = false
    /// The channel count the output unit was opened with: the requested count when the route
    /// carries it, otherwise 2.
    public private(set) var outputChannels = 2
    /// Called on the device's queue each time the output has (re)opened, with the speaker of each
    /// device channel.
    public var onPlayoutFormatChange: (@Sendable (_ speakers: [NvstSpeaker?]) -> Void)?
    private var requestedPlayoutChannels: Int
    private var raisedPreferredChannels = false
    public private(set) var inputChannels = 1
    public let outputSampleRate = 48_000.0
    public let inputSampleRate = 48_000.0
    public var outputPathLatencySeconds: TimeInterval {
        let session = AVAudioSession.sharedInstance()
        return session.outputLatency + session.ioBufferDuration
    }
    public var hasUsableOutputDevice: Bool { isPlayoutRunning }
    public private(set) var lastStartStatus: OSStatus = noErr
    private let queue = DispatchQueue(label: "OpenNOW.NVST.AudioDevice")
    private let capturesMicrophone: Bool
    private var unit: AudioUnit?
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var preferredInputDeviceUID: String?
    private var wantsRunning = false
    private var captureScratch = [Int16](repeating: 0, count: 16_384)
    private var lastLevelAt: UInt64 = 0

    public init(playoutChannelCount: Int = 2, capturesMicrophone: Bool = false,
                monitorsDefaultOutputDevice: Bool = true, preferredInputDeviceUID: String? = nil) {
        requestedPlayoutChannels = NvstCoreAudioFormat.supportedPlayoutChannelCount(playoutChannelCount)
        self.capturesMicrophone = capturesMicrophone
        self.preferredInputDeviceUID = preferredInputDeviceUID
        if monitorsDefaultOutputDevice {
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.restartAfterRouteChange() }
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.ended.rawValue else { return }
                self?.restartAfterRouteChange()
            }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        stop()
    }

    public func start() {
        queue.sync {
            wantsRunning = true
            startLocked()
        }
    }

    public func stop() {
        queue.sync {
            wantsRunning = false
            stopLocked()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    public func setPreferredInputDevice(uid: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            preferredInputDeviceUID = uid
            if wantsRunning { stopLocked(); startLocked() }
        }
    }

    /// Reopens the output for another channel count: the seat names its layout only after the
    /// device has started.
    public func setPlayoutChannelCount(_ count: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let supported = NvstCoreAudioFormat.supportedPlayoutChannelCount(count)
            guard supported != requestedPlayoutChannels else { return }
            requestedPlayoutChannels = supported
            if wantsRunning { stopLocked(); startLocked() }
        }
    }

    public var captureDeviceState: (uniqueID: String?, isFallback: Bool) {
        let actual = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        return (actual, preferredInputDeviceUID.map { $0 != actual } ?? false)
    }

    private func restartAfterRouteChange() {
        queue.async { [weak self] in
            guard let self, wantsRunning else { return }
            stopLocked()
            startLocked()
            onInputDeviceListChange?()
            let state = captureDeviceState
            onCaptureDeviceChange?(NvstCaptureDeviceChange(resolvedUniqueID: state.uniqueID,
                preferredUniqueID: preferredInputDeviceUID, isFallback: state.isFallback))
        }
    }

    private func startLocked() {
        guard unit == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            #if os(tvOS)
            let microphoneOptions: AVAudioSession.CategoryOptions = []
            #else
            let microphoneOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
            #endif
            try session.setCategory(capturesMicrophone ? .playAndRecord : .playback,
                mode: capturesMicrophone ? .default : .moviePlayback,
                options: capturesMicrophone ? microphoneOptions : [])
            try session.setPreferredSampleRate(outputSampleRate)
            try session.setPreferredIOBufferDuration(0.005)
            // Stereo sessions leave the session's channel preference alone, as they always have;
            // it is only put back to 2 after a surround stream raised it.
            if requestedPlayoutChannels > 2 {
                try? session.setPreferredOutputNumberOfChannels(
                    min(requestedPlayoutChannels, session.maximumOutputNumberOfChannels))
                raisedPreferredChannels = true
            } else if raisedPreferredChannels {
                try? session.setPreferredOutputNumberOfChannels(2)
                raisedPreferredChannels = false
            }
            if capturesMicrophone, let uid = preferredInputDeviceUID {
                try session.setPreferredInput(session.availableInputs?.first { $0.uid == uid })
            }
            try session.setActive(true)
            inputChannels = max(1, min(2, session.inputNumberOfChannels))
            outputChannels = max(2, NvstCoreAudioFormat.playoutChannelCount(
                requested: requestedPlayoutChannels, deviceChannels: session.outputNumberOfChannels))
            let labels = session.currentRoute.outputs.first?.channels?.map(\.channelLabel) ?? []
            let speakers = NvstAudioPlacement.speakers(forChannelLabels: labels, channelCount: outputChannels)
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_RemoteIO, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else {
                lastStartStatus = kAudio_ParamError
                return
            }
            var created: AudioUnit?
            try check(AudioComponentInstanceNew(component, &created))
            guard let created else { lastStartStatus = kAudio_ParamError; return }
            unit = created
            var enabled: UInt32 = capturesMicrophone ? 1 : 0
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &enabled, UInt32(MemoryLayout<UInt32>.size)))
            var output = NvstCoreAudioFormat.linear16Format(sampleRate: outputSampleRate, channels: UInt32(outputChannels))
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 0, &output, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var callback = AURenderCallbackStruct(inputProc: nvstIOSPlayout,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            var maximum: UInt32 = 4096
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maximum, UInt32(MemoryLayout<UInt32>.size)))
            if capturesMicrophone {
                var input = NvstCoreAudioFormat.linear16Format(sampleRate: inputSampleRate, channels: UInt32(inputChannels))
                try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output, 1, &input, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
                var capture = AURenderCallbackStruct(inputProc: nvstIOSCapture,
                    inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
                try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global, 1, &capture, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            }
            try check(AudioUnitInitialize(created))
            try check(AudioOutputUnitStart(created))
            isPlayoutRunning = true
            isCaptureRunning = capturesMicrophone
            lastStartStatus = noErr
            onPlayoutFormatChange?(speakers)
        } catch {
            if lastStartStatus == noErr { lastStartStatus = kAudio_ParamError }
            stopLocked()
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            lastStartStatus = status
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func stopLocked() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        isPlayoutRunning = false
        isCaptureRunning = false
    }

    fileprivate func render(_ frames: UInt32, output: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let output else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let sampleCount = Int(frames) * outputChannels
        guard let first = buffers.first, buffers.count == 1, let base = first.mData,
              Int(first.mDataByteSize) >= sampleCount * 2 else {
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        let samples = base.assumingMemoryBound(to: Int16.self)
        if let fillPlayout { fillPlayout(samples, sampleCount) }
        else { samples.update(repeating: 0, count: sampleCount) }
        onGameAudio?(UnsafeRawPointer(output), frames, outputSampleRate, UInt32(outputChannels))
        if isPlayoutMuted { memset(base, 0, sampleCount * 2) }
        return noErr
    }

    fileprivate func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, Int(frames) * inputChannels <= captureScratch.count else { return kAudio_ParamError }
        return captureScratch.withUnsafeMutableBufferPointer { scratch in
            guard let base = scratch.baseAddress else { return kAudio_ParamError }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(inputChannels), mDataByteSize: frames * UInt32(inputChannels * 2), mData: base))
            let status = AudioUnitRender(unit, flags, time, 1, frames, &list)
            guard status == noErr else { return status }
            guard isMicrophoneCaptureEnabled?() == true else { return noErr }
            withUnsafePointer(to: &list) { onMicrophoneAudio?(UnsafeRawPointer($0), frames, inputSampleRate, UInt32(inputChannels)) }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastLevelAt >= 50_000_000 {
                lastLevelAt = now
                onMicrophoneLevel?(NvstCoreAudioFormat.level(of: base, count: Int(frames) * inputChannels))
            }
            return noErr
        }
    }
}

private let nvstIOSPlayout: AURenderCallback = { context, _, _, _, frames, output in
    let device = Unmanaged<NvstCoreAudioDevice>.fromOpaque(context).takeUnretainedValue()
    return device.render(frames, output: output)
}

private let nvstIOSCapture: AURenderCallback = { context, flags, time, _, frames, _ in
    let device = Unmanaged<NvstCoreAudioDevice>.fromOpaque(context).takeUnretainedValue()
    return device.capture(flags, time: time, frames: frames)
}
