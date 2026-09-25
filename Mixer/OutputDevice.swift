//
//  OutputDevice.swift
//  Mixer
//

import AudioToolbox
import CoreAudio

/// システムの既定の出力デバイス（スピーカー、ヘッドホンなど）の操作
enum OutputDevice {
    static func defaultID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func defaultUID() -> String? {
        guard let id = defaultID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    /// 既定の出力デバイスの音量（0.0〜1.0）。音量を変えられないデバイス（HDMI など）は nil
    static var volume: Double? {
        get {
            guard let id = defaultID() else { return nil }
            var address = volumeAddress
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
            return Double(value)
        }
        set {
            guard let newValue, let id = defaultID() else { return }
            var address = volumeAddress
            var value = Float32(newValue)
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    /// 既定の出力デバイスが切り替わったとき、または音量が（音量キーなどで）変わったときに呼ぶ
    static func observe(onDeviceChange: @escaping () -> Void, onVolumeChange: @escaping () -> Void) -> Observer {
        Observer(onDeviceChange: onDeviceChange, onVolumeChange: onVolumeChange)
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    final class Observer {
        private let volumeListener: AudioObjectPropertyListenerBlock
        private var deviceListener: AudioObjectPropertyListenerBlock?
        private var observedDevice: AudioObjectID?

        fileprivate init(onDeviceChange: @escaping () -> Void, onVolumeChange: @escaping () -> Void) {
            volumeListener = { _, _ in onVolumeChange() }
            let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.observeVolumeOfDefaultDevice()
                onDeviceChange()
            }
            self.deviceListener = deviceListener

            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
            observeVolumeOfDefaultDevice()
        }

        /// 音量の監視先を、今の既定デバイスに付け替える
        private func observeVolumeOfDefaultDevice() {
            var address = OutputDevice.volumeAddress
            if let observedDevice {
                AudioObjectRemovePropertyListenerBlock(observedDevice, &address, .main, volumeListener)
            }
            observedDevice = OutputDevice.defaultID()
            if let observedDevice {
                AudioObjectAddPropertyListenerBlock(observedDevice, &address, .main, volumeListener)
            }
        }
    }
}
