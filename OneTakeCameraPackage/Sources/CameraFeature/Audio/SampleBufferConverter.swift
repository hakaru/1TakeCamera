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
        var asbd = fmt.streamDescription.pointee
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
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

    // MARK: - Format Reset

    /// Clears the cached bypass/convert decision and AVAudioConverter.
    /// Call this when the audio route changes while NOT recording so the next buffer
    /// re-evaluates the input format (e.g. after plugging in a USB-C interface).
    func resetFormat() {
        bypassConverter = nil
        inputFormat = nil
        converter = nil
        logger.info("SampleBufferConverter: format cache cleared (route change)")
    }

    // MARK: - CMSampleBuffer → Float32 stereo

    // Bypass flag: set once we confirm the capture format matches internal format.
    // nil = not yet determined; true = bypass; false = must convert.
    private var bypassConverter: Bool?

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

        // Log capture format once, then decide bypass vs. convert path.
        if bypassConverter == nil {
            logger.info("""
                capture format: sampleRate=\(asbd.mSampleRate, privacy: .public) \
                channels=\(asbd.mChannelsPerFrame, privacy: .public) \
                bitsPerChannel=\(asbd.mBitsPerChannel, privacy: .public) \
                formatFlags=\(asbd.mFormatFlags, privacy: .public) \
                formatID=\(asbd.mFormatID, privacy: .public) \
                bytesPerFrame=\(asbd.mBytesPerFrame, privacy: .public) \
                bytesPerPacket=\(asbd.mBytesPerPacket, privacy: .public) \
                framesPerPacket=\(asbd.mFramesPerPacket, privacy: .public)
                """)

            // Conditions for bypass:
            //   • Float32 PCM (kAudioFormatLinearPCM, kAudioFormatFlagIsFloat)
            //   • Non-interleaved (kAudioFormatFlagIsNonInterleaved)
            //   • 48 kHz
            //   • 1 or 2 channels
            let isFloat32     = asbd.mFormatID == kAudioFormatLinearPCM &&
                                (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let is48k         = abs(asbd.mSampleRate - Self.internalSampleRate) < 1
            let isBypassable  = isFloat32 && isNonInterleaved && is48k &&
                                (asbd.mChannelsPerFrame == 1 || asbd.mChannelsPerFrame == 2)

            bypassConverter = isBypassable
            if isBypassable {
                logger.info("SampleBufferConverter: AVAudioConverter BYPASSED (capture matches internal format, channels=\(asbd.mChannelsPerFrame, privacy: .public))")
            } else {
                logger.info("SampleBufferConverter: AVAudioConverter ACTIVE (format mismatch)")
            }
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // --- Bypass path -------------------------------------------------------
        if bypassConverter == true {
            return bypassToFloat32Buffer(
                blockBuffer: blockBuffer,
                asbd: asbd,
                frameCount: frameCount
            )
        }

        // --- AVAudioConverter path ---------------------------------------------
        return convertToFloat32Buffer(
            blockBuffer: blockBuffer,
            asbd: asbd,
            frameCount: frameCount
        )
    }

    // MARK: - Bypass path (no AVAudioConverter)

    /// Wraps capture Float32 non-interleaved data directly into an AVAudioPCMBuffer.
    /// If mono, duplicates channel 0 into channel 1 (no mixing, no silence).
    private func bypassToFloat32Buffer(
        blockBuffer: CMBlockBuffer,
        asbd: AudioStreamBasicDescription,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCount
        ) else {
            logger.error("[bypass] Failed to allocate output AVAudioPCMBuffer")
            return nil
        }
        outputBuffer.frameLength = frameCount

        guard let channelData = outputBuffer.floatChannelData else {
            logger.error("[bypass] Output buffer has no floatChannelData")
            return nil
        }

        // Non-interleaved: each channel is a separate contiguous plane.
        // mBytesPerFrame == 4 (one Float32 per frame per channel).
        let bytesPerChannel = Int(frameCount) * MemoryLayout<Float>.size
        let captureChannels = Int(asbd.mChannelsPerFrame)

        // Obtain a raw pointer to the block buffer data
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
            logger.error("[bypass] CMBlockBufferGetDataPointer failed: \(bbStatus, privacy: .public)")
            return nil
        }

        let expectedBytes = bytesPerChannel * captureChannels
        guard totalLength >= expectedBytes else {
            logger.error("[bypass] Block buffer too small: \(totalLength) < \(expectedBytes)")
            return nil
        }

        // Copy channel 0 (L)
        let src0 = UnsafeRawPointer(dataPointer)
        memcpy(channelData[0], src0, bytesPerChannel)

        if captureChannels >= 2 {
            // Stereo: copy channel 1 (R) from the second plane
            let src1 = UnsafeRawPointer(dataPointer.advanced(by: bytesPerChannel))
            memcpy(channelData[1], src1, bytesPerChannel)
        } else {
            // Mono: duplicate L → R
            memcpy(channelData[1], src0, bytesPerChannel)
        }

        return outputBuffer
    }

    // MARK: - AVAudioConverter path

    private func convertToFloat32Buffer(
        blockBuffer: CMBlockBuffer,
        asbd: AudioStreamBasicDescription,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        // Build or reuse AVAudioConverter
        if inputFormat == nil || inputFormat?.streamDescription.pointee != asbd {
            var asbdCopy = asbd
            guard let inFmt = AVAudioFormat(streamDescription: &asbdCopy) else {
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

    /// Re-wrap a processed AVAudioPCMBuffer into a CMSampleBuffer.
    ///
    /// The original `timingInfo.presentationTimeStamp` is preserved as-is (PTS authority
    /// comes from the capture clock). However, `duration` is recomputed from the
    /// post-conversion frame count at the internal sample rate (48kHz), because
    /// AVAudioConverter may change the sample count when doing sample-rate conversion
    /// (e.g. 44100 mono → 48000 stereo). Using the original duration would introduce
    /// accumulated drift proportional to the sample-rate ratio.
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
        guard bbStatus == kCMBlockBufferNoErr, let blockBuffer else {
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

        // Recompute duration from the post-conversion frame count at 48kHz.
        // PTS is preserved from the original capture timing.
        var timingInfoCopy = CMSampleTimingInfo(
            duration: CMTime(
                value: CMTimeValue(frameCount),
                timescale: CMTimeScale(Self.internalSampleRate)
            ),
            presentationTimeStamp: timingInfo.presentationTimeStamp,
            decodeTimeStamp: timingInfo.decodeTimeStamp
        )
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
