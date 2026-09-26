//
//  AppVolumeTap.swift
//  Mixer
//

import AudioToolbox
import CoreAudio
import Accelerate
import Synchronization
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mixer", category: "tap")

/// オーディオスレッドから読む音量。ロックを使わずに読み書きできるよう Float をビット列で持つ
nonisolated final class Gain: Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float) {
        bits = Atomic(value.bitPattern)
    }

    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// 1アプリ分の音量制御。
///
/// 仕組み：対象プロセスの音を Process Tap で横取りし（元の音はミュートされる）、
/// 出力デバイスと Tap を束ねた Aggregate Device 上で、音量を掛けてから出力し直す。
final class AppVolumeTap {
    let processObjectIDs: [AudioObjectID]
    let gain: Gain

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(processObjectIDs: [AudioObjectID], outputUID: String, gain: Float) throws(TapError) {
        self.processObjectIDs = processObjectIDs
        self.gain = Gain(gain)

        do {
            try start(outputUID: outputUID)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    private func start(outputUID: String) throws(TapError) {
        // 1. 対象プロセスの音をステレオにまとめて取り出す Tap。取り出している間、元の音は鳴らなくなる
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Process Tap の作成")

        // 2. 出力デバイス + Tap を1つにまとめた、このアプリ専用の非公開デバイス
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Aggregate Device の作成")

        // 3. Tap の音（入力）に音量を掛けて、出力へ書き戻す
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, Self.makeIOBlock(gain: gain)), "IOProc の作成")
        try check(AudioDeviceStart(aggregateID, ioProcID), "再生の開始")
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// オーディオスレッドで呼ばれる処理。メモリ確保やロックはしないこと
    nonisolated private static func makeIOBlock(gain: Gain) -> AudioDeviceIOBlock {
        { _, inputData, _, outputData, _ in
            var volume = gain.value
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)

            for (index, output) in outputs.enumerated() {
                guard let outData = output.mData else { continue }
                let outCount = Int(output.mDataByteSize) / MemoryLayout<Float>.size

                guard index < inputs.count, let inData = inputs[index].mData else {
                    memset(outData, 0, Int(output.mDataByteSize))
                    continue
                }
                let inCount = Int(inputs[index].mDataByteSize) / MemoryLayout<Float>.size
                let count = min(inCount, outCount)
                vDSP_vsmul(inData.assumingMemoryBound(to: Float.self), 1, &volume,
                           outData.assumingMemoryBound(to: Float.self), 1, vDSP_Length(count))
                if count < outCount {
                    memset(outData.assumingMemoryBound(to: Float.self) + count, 0, (outCount - count) * MemoryLayout<Float>.size)
                }
            }
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws(TapError) {
        guard status == noErr else {
            logger.error("\(step, privacy: .public) に失敗: \(status)")
            throw TapError(step: step, status: status)
        }
    }
}

struct TapError: Error {
    let step: String
    let status: OSStatus
}

/// アプリごとの AppVolumeTap をまとめて管理する。
/// 音量 100% かつミュートなしのアプリには Tap を作らない（遅延も負荷も増やさないため）
final class AppVolumeTapManager {
    private var taps: [String: AppVolumeTap] = [:]
    private var outputUID: String?

    /// - Parameters:
    ///   - gains: アプリID → 音量（ミュートなら 0）
    ///   - processes: アプリID → そのアプリの Core Audio プロセスオブジェクト
    func sync(gains: [String: Float], processes: [String: [AudioObjectID]]) {
        guard let outputUID = outputUID ?? OutputDevice.defaultUID() else { return }
        self.outputUID = outputUID

        // 100% に戻った・終了したアプリの Tap を外す
        for appID in taps.keys where !(gains[appID].map { Self.needsTap($0) } ?? false) || processes[appID] == nil {
            taps[appID] = nil
        }

        for (appID, gain) in gains where Self.needsTap(gain) {
            guard let processIDs = processes[appID], !processIDs.isEmpty else { continue }

            if let tap = taps[appID], tap.processObjectIDs == processIDs {
                tap.gain.value = gain
                continue
            }
            // プロセス構成が変わったら作り直す（古い Tap は置き換え時に破棄される）
            taps[appID] = nil
            do {
                taps[appID] = try AppVolumeTap(processObjectIDs: processIDs, outputUID: outputUID, gain: gain)
                logger.debug("Tap 作成: \(appID, privacy: .public)")
            } catch {
                // 失敗した手順とエラーコードは AppVolumeTap 側でログに出している
                logger.error("Tap を作れませんでした: \(appID, privacy: .public)")
            }
        }
    }

    /// 出力デバイスが変わったら全 Tap を作り直す
    func outputDeviceChanged(gains: [String: Float], processes: [String: [AudioObjectID]]) {
        taps.removeAll()
        outputUID = nil
        sync(gains: gains, processes: processes)
    }

    private static func needsTap(_ gain: Float) -> Bool {
        gain < 0.999
    }
}
