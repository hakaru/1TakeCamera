// SampleBufferConverter.swift
// Converts CMSampleBuffer ↔ Float32 stereo @ 48kHz, preserving CMSampleTimingInfo.
// Format conversion happens here — once only per spec.

import AVFoundation
import CoreMedia
import os

private let logger = Logger(subsystem: "net.hakaru.OneTakeCamera", category: "Capture")

/// Converts between CMSampleBuffer (capture format) and Float32 stereo @ 48kHz.
/// All methods are called from the capture serial queue.
final class SampleBufferConverter: @unchecked Sendable {

    // MARK: - Internal Format

    static let internalSampleRate: Double = 48000
    static let internalChannelCount: UInt32 = 2

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat

    // Pre-computed CMAudioFormatDescription for the internal format
    let outputCMFormat: CMAudioFormatDescription

    init?() {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.internalSampleRate,
            channels: Self.internalChannelCount,
            interleaved: false
        ) else {
            logger.error("Failed to create internal AVAudioFormat")
            return nil
        }
        self.outputFormat = fmt

        var cmFmt: CMAudioFormatDescription?
        let asbd = fmt.streamDescription.pointee
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &UnsafeMutablePointer(mutating: [asbd]).pointee,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &cmFmt
        )
        guard status == noErr, let cmFmt else {
            logger.error("Failed to create CMAudioFormatDescription: \(status, privacy: .public)")
            return nil
        }
        self.outputCMFormat = cmFmt
    }

    // MARK: - CMSampleBuffer → Float32 stereo

    /// Convert a capture CMSampleBuffer to an AVAudioPCMBuffer in internal format.
    /// Returns `nil` on failure; caller must drop the buffer and increment counter.
    func toFloat32Buffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            logger.error("CMSampleBuffer has no data buffer")
            return nil
        }
        guard let cmFmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            logger.error("CMSampleBuffer has no format description")
            return nil
        }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cmFmtDesc)?.pointee
        guard let asbd else {
            logger.error("Could not get ASBD from format description")
            return nil
        }

        // Build or reuse AVAudioConverter
        if inputFormat == nil || inputFormat?.streamDescription.pointee != asbd {
            guard let inFmt = AVAudioFormat(streamDescription: &UnsafeMutablePointer(mutating: [asbd]).pointee) else {
                logger.error("Failed to create AVAudioFormat from ASBD")
                return nil
            }
            inputFormat = inFmt
            converter = AVAudioConverter(from: inFmt, to: outputFormat)
            if converter == nil {
                logger.error("Failed to create AVAudioConverter from \(inFmt, privacy: .public) to \(self.outputFormat, privacy: .public)")
                return nil
            }
            logger.info("AVAudioConverter created: \(inFmt, privacy: .public) → \(self.outputFormat, privacy: .public)")
        }
        guard let converter else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // Compute output frame count for sample rate conversion
        let inputSampleRate = asbd.mSampleRate
        let outputSampleRate = outputFormat.sampleRate
        let outputFrameCount: AVAudioFrameCount
        if abs(inputSampleRate - outputSampleRate) < 1 {
            outputFrameCount = frameCount
        } else {
            outputFrameCount = AVAudioFrameCount(
                ceil(Double(frameCount) * outputSampleRate / inputSampleRate)
            )
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else {
            logger.error("Failed to allocate output AVAudioPCMBuffer")
            return nil
        }

        // Build input PCMBuffer from CMSampleBuffer data
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat!, frameCapacity: frameCount) else {
            logger.error("Failed to allocate input AVAudioPCMBuffer")
            return nil
        }
        inputBuffer.frameLength = frameCount

        var dataPointer: UnsafeMutablePointer<Int8>?
        var totalLength = 0
        let bbStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard bbStatus == kCMBlockBufferNoErr, let dataPointer else {
            logger.error("CMBlockBufferGetDataPointer failed: \(bbStatus, privacy: .public)")
            return nil
        }

        let byteCount = Int(inputBuffer.frameLength) * Int(asbd.mBytesPerFrame)
        if totalLength < byteCount {
            logger.error("Block buffer too small: \(totalLength) < \(byteCount)")
            return nil
        }
        memcpy(inputBuffer.audioBufferList.pointee.mBuffers.mData, dataPointer, byteCount)

        // Convert
        var convertError: NSError?
        var consumed = false
        let result = converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if result == .error || convertError != nil {
            logger.error("AVAudioConverter failed: \(convertError?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }

        return outputBuffer
    }

    // MARK: - Float32 stereo → CMSampleBuffer

    /// Re-wrap a processed AVAudioPCMBuffer into a CMSampleBuffer,
    /// stamping it with the original capture timing (PTS, duration, sample count).
    func toCMSampleBuffer(
        _ pcmBuffer: AVAudioPCMBuffer,
        timingInfo: CMSampleTimingInfo
    ) -> CMSampleBuffer? {
        guard let channelData = pcmBuffer.floatChannelData else {
            logger.error("PCM buffer has no float channel data")
            return nil
        }
        let frameCount = Int(pcmBuffer.frameLength)
        let bytesPerFrame = MemoryLayout<Float>.size
        let totalBytes = frameCount * bytesPerFrame
        let channelCount = Int(pcmBuffer.format.channelCount)

        // Allocate a CMBlockBuffer and copy interleaved (or non-interleaved) data
        // We keep non-interleaved Float32 (the internal format)
        var blockBuffer: CMBlockBuffer?
        var bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes * channelCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes * channelCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, var blockBuffer else {
            logger.error("CMBlockBufferCreateWithMemoryBlock failed: \(bbStatus, privacy: .public)")
            return nil
        }

        // For simplicity in PoC: interleave L+R into the block buffer
        var interleavedBytes = [Float](repeating: 0, count: frameCount * channelCount)
        let leftPtr = channelData[0]
        let rightPtr = channelCount >= 2 ? channelData[1] : channelData[0]
        for i in 0..<frameCount {
            interleavedBytes[i * 2]     = leftPtr[i]
            interleavedBytes[i * 2 + 1] = rightPtr[i]
        }
        bbStatus = CMBlockBufferReplaceDataBytes(
            with: interleavedBytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: totalBytes * channelCount
        )
        guard bbStatus == kCMBlockBufferNoErr else {
            logger.error("CMBlockBufferReplaceDataBytes failed: \(bbStatus, privacy: .public)")
            return nil
        }

        // Build an interleaved ASBD for the writer (AAC encoder expects interleaved)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.internalSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var cmFmtDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &cmFmtDesc
        )
        guard fmtStatus == noErr, let cmFmtDesc else {
            logger.error("CMAudioFormatDescriptionCreate failed: \(fmtStatus, privacy: .public)")
            return nil
        }

        var timingInfoCopy = timingInfo
        var outputSampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: cmFmtDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfoCopy,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &outputSampleBuffer
        )
        guard sbStatus == noErr, let outputSampleBuffer else {
            logger.error("CMSampleBufferCreate failed: \(sbStatus, privacy: .public)")
            return nil
        }

        return outputSampleBuffer
    }
}

// MARK: - Helpers

private extension AVAudioFormat {
    // Equatable-ish comparison via ASBD
}

extension AudioStreamBasicDescription: @retroactive Equatable {
    public static func == (lhs: AudioStreamBasicDescription, rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate &&
        lhs.mFormatID == rhs.mFormatID &&
        lhs.mFormatFlags == rhs.mFormatFlags &&
        lhs.mBytesPerPacket == rhs.mBytesPerPacket &&
        lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
        lhs.mBytesPerFrame == rhs.mBytesPerFrame &&
        lhs.mChannelsPerFrame == rhs.mChannelsPerFrame &&
        lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}
