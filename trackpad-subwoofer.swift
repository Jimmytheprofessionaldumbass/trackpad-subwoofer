// trackpad-subwoofer.swift
//
// Turns the Mac's Force Touch trackpad into a subwoofer, driven by the default input device.
//
//   default input device (CoreAudio AudioQueue)
//     -> mono mix
//     -> DC blocker (one-pole high-pass, 20 Hz)
//     -> 4th-order Butterworth low-pass (120 Hz)
//     -> bass envelope (RMS -> dBFS)  +  fundamental (normalised autocorrelation)
//     -> drive level 0...1  +  drive frequency 35...150 Hz
//     -> MultitouchSupport haptic actuation (private API)
//
// The haptic plumbing (dlopen of MultitouchSupport, MTActuator*, MTActuation*) is derived from
// nospeaker (https://github.com/os6/nospeaker), MIT licensed, Copyright (c) 2026 Cody Collier.
// Everything else here is new. See README.md for the full credits.
//
// Build: ./build.sh     Run: ./trackpad-subwoofer --help

import Foundation
import CoreAudio
import AudioToolbox
import Darwin

// MARK: - Options

/// Where the audio comes from.
enum Source: String {
    case output   // what the system is playing (a process tap)
    case input    // the microphone
}

struct Options {
    var source: Source = .output
    var excludeApp: String? = nil
    var cutoffHz: Double = 120      // low-pass corner: the top of the subwoofer band
    var highpassHz: Double = 20     // DC blocker corner
    var minDriveHz: Double = 60     // lowest frequency the motor is asked to make
    var maxDriveHz: Double = 150    // highest frequency the motor is asked to make
    var waveform: String = "sine"   // sine | square | sawtooth
    var floorDb: Double = -55       // below this, the bass counts as silence
    var ceilingDb: Double = -12     // at or above this, full drive
    var gamma: Double = 1.5         // >1 makes the response less eager
    var gain: Double = 1.0
    var maxLevel: Double = 0.8      // hard ceiling on motor strength
    var harmonic: Int = 0           // 0 = off; else a harmonic tone this many times the fundamental
    var harmonicAmp: Double = 0.35
    var attack: Double = 0.010      // seconds
    var release: Double = 0.120     // seconds
    var showMeter: Bool = true
    var listDevices: Bool = false
    var check: Bool = false
    var selfTest: Bool = false
    var dryRun: Bool = false
    var device: String? = nil
    var fixedHz: Double? = nil
    var feedbackGuard: Bool = true
    var feedbackDecay: Double = 1.0
    var preferExternal: Bool = false
}

var stopRequested = false

/// The range the trackpad's haptic motor can actually produce. Apple's own actuation tables
/// bottom out at 60 Hz (their lowest FrequencykHz is 0.06), and the encoder quantises the
/// requested frequency logarithmically onto that table. Asking for less doesn't give you less —
/// it gives you the lowest tone available, or a mushy one. So the drive is clamped here.
let hardwareMinHz: Double = 60
let hardwareMaxHz: Double = 3800

// Where the meter goes, and where errors go once the terminal has been silenced.
var outFD: Int32 = STDOUT_FILENO
var savedOut: Int32 = -1, savedErr: Int32 = -1

let helpText = """
trackpad-subwoofer — the Mac's Force Touch trackpad as a subwoofer, driven by the default input device.

  ./trackpad-subwoofer [options]

  --source WHICH     what to listen to: output (what the system is playing, the default)
                    or input (the microphone)
  --exclude-app NAME don't capture audio from apps whose bundle id contains NAME
                    (e.g. --exclude-app Spotify, so the program doesn't hear itself)
  --cutoff HZ       low-pass corner; the top of the sub band            (default 120)
  --highpass HZ     DC blocker corner                                   (default 20)
  --min-hz HZ       lowest motor frequency                              (default 60)
  --max-hz HZ       highest motor frequency                             (default 150)
  --waveform WHICH  tone shape: sine, square or sawtooth                (default sine)
                    square and sawtooth carry harmonics, which is what makes a
                    low fundamental audible on the trackpad
  --floor-db DB     input level treated as silence                      (default -55)
  --ceiling-db DB   input level that means full drive                   (default -12)
  --gamma G         response curve, >1 is less eager                     (default 1.5)
  --gain G          overall drive multiplier                            (default 1.0)
  --max-level L     hard ceiling on motor strength, 0...1               (default 0.8)
  --harmonic N      add a tone N times the fundamental, for audibility  (default 0, off)
  --harmonic-amp A  how loud that harmonic is, relative                 (default 0.35)
  --attack S        envelope attack time, seconds                       (default 0.010)
  --release S       envelope release time, seconds                      (default 0.120)
  --no-meter        don't print the level meter
  --list-devices    list input devices and exit
  --check           report the haptic and audio paths, then exit (captures nothing, vibrates nothing)
  --dry-run         capture and analyse, but don't drive the trackpad (silent, nothing to feel)
  --selftest        verify the filter and pitch tracking on synthetic signals, then exit
                    (no audio device, no haptic motor, makes no sound)
  --device WHICH    input device to listen to: a device id, or part of its name
                    (default: the system default input device)
  --fixed-hz HZ     drive one fixed frequency instead of following the bass pitch
  --no-feedback-guard
                    don't damp the motor when it starts hearing itself
  --feedback-decay DB  how far the level may fall over the lock window and still count
                    as a feedback loop (default 1.0)
  --external        drive an external Magic Trackpad instead of the built-in one
  --help            this text

Press ctrl-c to stop.
"""

func fail(_ message: String) -> Never {
    // Write to the saved stderr when the terminal is silenced, so errors never vanish.
    let fd = savedErr >= 0 ? savedErr : STDERR_FILENO
    let bytes = Array(("trackpad-subwoofer: " + message + "\n").utf8)
    bytes.withUnsafeBytes { buf in
        var off = 0
        while off < bytes.count {
            let n = write(fd, buf.baseAddress! + off, bytes.count - off)
            if n <= 0 { break }
            off += n
        }
    }
    exit(64)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    /// Reads the number after an option, or after the "=" in "--name=number".
    func value(_ i: inout Int, _ name: String) -> Double {
        let rest = args[i]
        if let eq = rest.firstIndex(of: "=") {
            return Double(rest[rest.index(after: eq)...]) ?? 0
        }
        i += 1
        guard i < args.count else { fail("missing a number after \(name)") }
        guard let d = Double(args[i]) else { fail("\(name) wants a number, got \"\(args[i])\"") }
        return d
    }

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--help", "-h":
            print(helpText); exit(0)
        case "--cutoff": o.cutoffHz = value(&i, arg)
        case "--source":
            i += 1
            guard i < args.count else { fail("missing a source after --source") }
            guard let s = Source(rawValue: args[i].lowercased()) else {
                fail("--source wants output or input, got \"\(args[i])\"")
            }
            o.source = s
        case "--exclude-app":
            i += 1
            guard i < args.count else { fail("missing an app name after --exclude-app") }
            o.excludeApp = args[i]
        case "--highpass": o.highpassHz = value(&i, arg)
        case "--min-hz": o.minDriveHz = value(&i, arg)
        case "--max-hz": o.maxDriveHz = value(&i, arg)
        case "--waveform":
            i += 1
            guard i < args.count else { fail("missing a waveform after --waveform") }
            let w = args[i].lowercased()
            guard ["sine", "square", "sawtooth"].contains(w) else {
                fail("--waveform wants sine, square or sawtooth, got \"\(args[i])\"")
            }
            o.waveform = w
        case "--floor-db": o.floorDb = value(&i, arg)
        case "--ceiling-db": o.ceilingDb = value(&i, arg)
        case "--gamma": o.gamma = value(&i, arg)
        case "--gain": o.gain = value(&i, arg)
        case "--max-level": o.maxLevel = value(&i, arg)
        case "--harmonic": o.harmonic = Int(value(&i, arg))
        case "--harmonic-amp": o.harmonicAmp = value(&i, arg)
        case "--attack": o.attack = value(&i, arg)
        case "--release": o.release = value(&i, arg)
        case "--no-meter": o.showMeter = false
        case "--list-devices": o.listDevices = true
        case "--check": o.check = true
        case "--selftest": o.selfTest = true
        case "--dry-run": o.dryRun = true
        case "--device":
            i += 1
            guard i < args.count else { fail("missing a device after --device") }
            o.device = args[i]
        case "--fixed-hz": o.fixedHz = value(&i, arg)
        case "--no-feedback-guard": o.feedbackGuard = false
        case "--feedback-decay": o.feedbackDecay = value(&i, arg)
        case "--external": o.preferExternal = true
        default:
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                // "--name=value" becomes "--name", "value" and is parsed from the start again.
                let name = String(arg[arg.startIndex..<eq])
                let rest = Array(args[(i + 1)...])
                args = [name, String(arg[arg.index(after: eq)...])] + rest
                i = 0
                continue
            }
            if arg.hasPrefix("-") { fail("unknown option \"\(arg)\". Try --help.") }
            fail("unexpected argument \"\(arg)\". Try --help.")
        }
        i += 1
    }

    guard o.cutoffHz > 0 else { fail("--cutoff must be positive") }
    guard o.highpassHz >= 0 else { fail("--highpass must not be negative") }
    guard o.minDriveHz > 0, o.maxDriveHz >= o.minDriveHz else { fail("--min-hz/--max-hz don't make a range") }
    guard o.ceilingDb > o.floorDb else { fail("--ceiling-db must be above --floor-db") }
    guard o.gain >= 0 else { fail("--gain must not be negative") }
    guard o.maxLevel >= 0, o.maxLevel <= 1 else { fail("--max-level must be 0...1") }
    guard o.attack > 0, o.release > 0 else { fail("--attack/--release must be positive") }
    guard o.harmonicAmp >= 0, o.harmonicAmp <= 1 else { fail("--harmonic-amp must be 0...1") }
    guard o.feedbackDecay >= 0 else { fail("--feedback-decay must not be negative") }
    if let hz = o.fixedHz {
        guard hz >= o.minDriveHz && hz <= o.maxDriveHz else { fail("--fixed-hz must be between --min-hz and --max-hz") }
    }
    return o
}

// MARK: - Terminal
//
// MultitouchSupport writes its own debug lines ("Recognized family…") to stdout when the
// actuator opens. Keep stdout/stderr pointed at /dev/null while running and write the meter
// through a saved duplicate of stdout, the way nospeaker does.

func silenceOthers() {
    fflush(stdout); fflush(stderr)
    savedOut = dup(STDOUT_FILENO); savedErr = dup(STDERR_FILENO)
    if savedOut >= 0 { outFD = savedOut }
    let null = open("/dev/null", O_WRONLY)
    if null >= 0 {
        dup2(null, STDOUT_FILENO); dup2(null, STDERR_FILENO); close(null)
    }
}

func unsilence() {
    guard savedOut >= 0 else { return }
    fflush(stdout); fflush(stderr)
    dup2(savedOut, STDOUT_FILENO); dup2(savedErr, STDERR_FILENO)
    close(savedOut); close(savedErr)
    savedOut = -1; savedErr = -1; outFD = STDOUT_FILENO
}

func out(_ s: String) {
    let bytes = Array(s.utf8)
    bytes.withUnsafeBytes { buf in
        var off = 0
        while off < bytes.count {
            let n = write(outFD, buf.baseAddress! + off, bytes.count - off)
            if n <= 0 { break }
            off += n
        }
    }
}

// MARK: - CoreAudio: devices

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var name: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
    }
    if status == noErr, let name {
        return (name.takeUnretainedValue() as String)
    }
    return "device \(id)"
}

/// The device's unique identifier (a CFString). AudioQueue selects its device by UID, not by ID.
func deviceUID(_ id: AudioDeviceID) -> CFString? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var uid: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &uid) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
    }
    return status == noErr ? uid?.takeUnretainedValue() : nil
}

/// The input device to listen to: the system default, unless `--device` picked another one.
/// `--device` takes a device id or part of a device name.
func resolveInputDevice(_ wanted: String?) -> AudioDeviceID? {
    guard let wanted, !wanted.isEmpty else { return defaultInputDevice() }

    let devices = allDeviceIDs().filter { hasInputStreams($0) }
    if let id = UInt32(wanted), devices.contains(id) { return id }

    let needle = wanted.lowercased()
    let matches = devices.filter { deviceName($0).lowercased().contains(needle) }
    if matches.count == 1 { return matches[0] }
    if matches.count > 1 {
        fail("--device \"\(wanted)\" matches \(matches.count) devices: \(matches.map { deviceName($0) }.joined(separator: ", ")). Be more specific.")
    }
    fail("no input device matches \"\(wanted)\". Run --list-devices to see what's available.")
}

/// The system default input device: the microphone this program listens to.
func defaultInputDevice() -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
    return id == 0 ? nil : id
}

func allDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioDeviceID>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, raw) == noErr else { return [] }
    let ids = raw.assumingMemoryBound(to: AudioDeviceID.self)
    return (0..<(Int(size) / MemoryLayout<AudioDeviceID>.size)).map { ids[$0] }
}

/// True when the device has at least one input stream.
func hasInputStreams(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioDevicePropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
    let list = raw.assumingMemoryBound(to: AudioBufferList.self)
    let buffers = UnsafeMutableRawPointer(list).assumingMemoryBound(to: AudioBuffer.self)
    var channels: UInt32 = 0
    for i in 0..<Int(list.pointee.mNumberBuffers) { channels += UInt32(buffers[i].mNumberChannels) }
    return channels > 0
}

func inputChannelCount(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioDevicePropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 1 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 1 }
    let list = raw.assumingMemoryBound(to: AudioBufferList.self)
    let buffers = UnsafeMutableRawPointer(list).assumingMemoryBound(to: AudioBuffer.self)
    var channels: UInt32 = 0
    for i in 0..<Int(list.pointee.mNumberBuffers) { channels += UInt32(buffers[i].mNumberChannels) }
    return max(1, Int(channels))
}

func nominalSampleRate(_ id: AudioDeviceID) -> Double {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioDevicePropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var rate: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return 48000 }
    return rate
}

// MARK: - DSP

/// One biquad section (RBJ cookbook). Two of them in series make a 4th-order Butterworth.
final class Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    func setLowPass(freq: Double, q: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * freq / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let a0 = 1 + alpha
        b0 = ((1 - cw) / 2) / a0
        b1 = (1 - cw) / a0
        b2 = b0
        a1 = (-2 * cw) / a0
        a2 = (1 - alpha) / a0
        reset()
    }

    func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// One-pole high-pass that keeps DC and infrasonic rumble out of the envelope.
final class DCBlocker {
    private var r = 0.997
    private var x1 = 0.0, y1 = 0.0

    func configure(freq: Double, sampleRate: Double) {
        r = 1 - (2 * Double.pi * freq / sampleRate)
        x1 = 0; y1 = 0
    }

    func process(_ x: Double) -> Double {
        let y = x - x1 + r * y1
        x1 = x; y1 = y
        return y
    }
}

/// A circular buffer of mono samples, written by the audio thread and read by the analysis thread.
final class RingBuffer {
    private var storage: [Float]
    private let capacity: Int
    private var writeIndex = 0
    private var total = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<count {
            storage[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % capacity
            total += 1
        }
    }

    /// Copies the most recent `n` samples into `dest`, oldest first. Returns how many were available.
    func copyLast(_ n: Int, into dest: inout [Float]) -> Int {
        lock.lock(); defer { lock.unlock() }
        let take = min(n, min(total, capacity))
        let start = total - take
        for i in 0..<take {
            dest[i] = storage[(start + i) % capacity]
        }
        return take
    }
}

/// Everything the audio thread does: mix to mono, strip DC, low-pass, and hand the result over.
final class InputProcessor {
    let ring = RingBuffer(capacity: 32768)
    let dc = DCBlocker()
    // Four cascaded biquads = an 8th-order Butterworth low-pass: 48 dB per octave. Four sections
    // rather than two, because a 4th-order filter leaves a 440 Hz tone only ~22 dB down, and the
    // pitch tracker will happily lock onto that leftover as if it were bass.
    let lp1 = Biquad()
    let lp2 = Biquad()
    let lp3 = Biquad()
    let lp4 = Biquad()
    private var channels = 1
    private var scratch = [Float](repeating: 0, count: 8192)

    func configure(sampleRate: Double, channels: Int, cutoff: Double, highpass: Double) {
        self.channels = max(1, channels)
        dc.configure(freq: max(0.5, highpass), sampleRate: sampleRate)
        // The four Q values are the 8th-order Butterworth pair.
        lp1.setLowPass(freq: cutoff, q: 0.50979642, sampleRate: sampleRate)
        lp2.setLowPass(freq: cutoff, q: 0.60134464, sampleRate: sampleRate)
        lp3.setLowPass(freq: cutoff, q: 0.89997620, sampleRate: sampleRate)
        lp4.setLowPass(freq: cutoff, q: 1.96157056, sampleRate: sampleRate)
    }

    /// Called on the audio thread. Does no allocation once configured.
    func process(data: UnsafePointer<Float>, sampleCount: Int) {
        let ch = channels
        let frames = sampleCount / ch
        guard frames > 0 else { return }
        var offset = 0
        while offset < frames {
            let chunk = min(frames - offset, scratch.count)
            for f in 0..<chunk {
                var sum = 0.0
                let base = (offset + f) * ch
                for c in 0..<ch { sum += Double(data[base + c]) }
                let mono = sum / Double(ch)
                let filtered = lp4.process(lp3.process(lp2.process(lp1.process(dc.process(mono)))))
                scratch[f] = Float(filtered)
            }
            ring.write(scratch, count: chunk)
            offset += chunk
        }
    }
}

// MARK: - Shared control state (analysis thread -> haptic thread)

final class ControlState {
    private let lock = NSLock()
    private var _level = 0.0
    private var _hz = 60.0
    private var _db = -120.0
    private var _confidence = 0.0
    private var _driveHz = 0.0
    private var _driveLevel = 0.0

    func update(level: Double, hz: Double, db: Double, confidence: Double) {
        lock.lock()
        _level = level; _hz = hz; _db = db; _confidence = confidence
        lock.unlock()
    }

    /// What the motor was last asked to do, so the analysis can tell whether it's hearing itself.
    func updateDrive(hz: Double, level: Double) {
        lock.lock()
        _driveHz = hz; _driveLevel = level
        lock.unlock()
    }

    func read() -> (level: Double, hz: Double, db: Double, confidence: Double) {
        lock.lock(); defer { lock.unlock() }
        return (_level, _hz, _db, _confidence)
    }

    func readDrive() -> (hz: Double, level: Double) {
        lock.lock(); defer { lock.unlock() }
        return (_driveHz, _driveLevel)
    }
}

// MARK: - The haptic motor (MultitouchSupport, private framework, resolved at run time)
//
// From nospeaker: MTActuationCreateFromDictionary takes a description of a vibration — a list of
// sine tones, each with a frequency, a strength and a length — and MTActuationActuate plays it.

let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)

func sym<T>(_ name: String, _: T.Type) -> T? {
    guard let mt, let p = dlsym(mt, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

let createList = sym("MTDeviceCreateList", CreateList.self)
let getID = sym("MTDeviceGetDeviceID", GetID.self)
let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
let actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
let actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self)
let actuatorClose = sym("MTActuatorClose", ActuatorClose.self)
let actuationCreate = sym("MTActuationCreateFromDictionary", ActuationCreate.self)
let actuationPlay = sym("MTActuationActuate", ActuationPlay.self)

var motor: CFTypeRef?
var motorPointer: UnsafeMutableRawPointer?

/// Opens the haptic motor. Prefers the built-in trackpad unless `preferExternal` is set.
func openMotor(preferExternal: Bool) -> CFTypeRef {
    guard let createList, let getID, let actuatorCreate, let actuatorOpen, actuationCreate != nil, actuationPlay != nil else {
        fail("this version of macOS doesn't have the trackpad functions this needs.")
    }
    guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
        fail("no trackpad found. A Force Touch trackpad is needed: a MacBook from 2015 on, or a Magic Trackpad 2 or newer.")
    }
    var ids: [(id: UInt64, builtIn: Bool)] = []
    for i in 0..<CFArrayGetCount(list) {
        guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
        let dev = UnsafeMutableRawPointer(mutating: raw)
        var id: UInt64 = 0
        if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
    }
    if preferExternal {
        for d in ids where !d.builtIn {
            if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 { return ref }
        }
        fail("--external was given, but no external trackpad was found.")
    }
    for d in ids.sorted(by: { $0.builtIn && !$1.builtIn }) {
        if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 { return ref }
    }
    fail("found a trackpad, but it has no haptic motor (Force Touch).")
}

/// The tone-shape names the encoder recognises. It is case-sensitive: "Sine" encodes as type 1,
/// while "sine" silently falls back to 0 (Gaussian) — no error, just the wrong shape. So the
/// user's option has to be mapped to the exact dictionary string explicitly.
func waveformName(_ option: String) -> String {
    switch option.lowercased() {
    case "square": return "Square"
    case "sawtooth": return "Sawtooth"
    default: return "Sine"
    }
}

/// Plays one or more sine tones for `ms` milliseconds at `level` (0...1). The tones' amplitudes are
/// normalised so they add up to 1: past that the motor is louder, but the driver starts to stall.
///
/// `waveform` is the tone shape: "Sine", "Square" or "Sawtooth". Square and sawtooth carry
/// harmonics that a pure sine cannot, and those harmonics are what make the glass actually
/// loud — the fundamental alone is weak at the low end of the trackpad's range.
func actuate(tones: [(hz: Double, amp: Double)], ms: Double, level: Float, waveform: String = "Sine") {
    guard let motorPointer, !tones.isEmpty else { return }
    let sum = max(tones.reduce(0) { $0 + $1.amp }, 0.0001)
    let shape: [String: Any] = [
        "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
        "Tones": tones.map {
            ["Type": waveform, "Amplitude": $0.amp / sum, "DurationMS": ms, "DelayMS": 0.0, "FrequencykHz": $0.hz / 1000]
        },
    ]
    guard let act = actuationCreate!(shape as CFDictionary, 0) else { return }
    _ = actuationPlay!(act, motorPointer, 0, min(1, max(0, level)), 0)
    Unmanaged<AnyObject>.fromOpaque(act).release()
}

// MARK: - Audio capture
//
// Two sources:
//   output (default) -- a CoreAudio process tap, which captures what the system is playing
//                       (macOS 14.2+). The tap is wrapped in an aggregate device, which is
//                       what AudioQueue reads from.
//   input            -- the microphone, for when you want the room's bass instead of the
//                       computer's.
//
// The tap must be PUBLIC: a private aggregate device yields pure silence.

var processor = InputProcessor()
var control = ControlState()

let inputCallback: AudioQueueInputCallback = { _, queue, buffer, _, _, _ in
    let bytes = Int(buffer.pointee.mAudioDataByteSize)
    let samples = bytes / MemoryLayout<Float>.size
    if samples > 0 {
        let data = buffer.pointee.mAudioData
        processor.process(data: UnsafeRawPointer(data).assumingMemoryBound(to: Float.self), sampleCount: samples)
    }
    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
}

var audioQueue: AudioQueueRef?
var tapID = AudioObjectID(0)
var aggregateID = AudioObjectID(0)

/// The tap's own UID. Note this is kAudioTapPropertyUID ('tuid'), NOT
/// kAudioDevicePropertyDeviceUID -- asking a tap for a device UID crashes CoreAudio.
func tapUID(_ id: AudioObjectID) -> CFString? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString>.size)
    var value: CFString = "?" as CFString
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
    }
    guard status == noErr else { return nil }
    return value
}

/// Creates a tap on all system output and wraps it in an aggregate device that AudioQueue can read.
/// Returns the aggregate's device id and its format.
@available(macOS 14.2, *)
func createOutputTap(excludeApp: String?) -> (device: AudioDeviceID, rate: Double, channels: Int) {
    let description: CATapDescription
    if let excludeApp {
        // Exclude one process by name, so the program doesn't hear itself.
        let excluded = processIDs(named: excludeApp)
        description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
    } else {
        description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    }
    description.name = "trackpad-subwoofer"

    var newTap = AudioObjectID(0)
    let status = AudioHardwareCreateProcessTap(description, &newTap)
    guard status == noErr, newTap != 0 else {
        fail("couldn't create a system-audio tap (error \(status)). This needs macOS 14.2 or later.")
    }
    tapID = newTap
    guard let uid = tapUID(newTap) else {
        fail("the tap didn't report a UID.")
    }

    let aggregateUID = "trackpad-subwoofer-\(UUID().uuidString)"
    let aggregate: [String: Any] = [
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceNameKey: "Trackpad Subwoofer",
        kAudioAggregateDeviceIsPrivateKey: 1,     // private: only this process sees it
        kAudioAggregateDeviceTapAutoStartKey: 1,   // without this the tap never activates
        kAudioAggregateDeviceTapListKey: [["uid": uid]],
    ]
    var newAggregate = AudioObjectID(0)
    let aggStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
    guard aggStatus == noErr, newAggregate != 0 else {
        fail("couldn't wrap the tap in an aggregate device (error \(aggStatus)).")
    }
    aggregateID = newAggregate

    // The tap's native format: 48 kHz, stereo, float.
    var rate = 48000.0
    var channels = 2
    var formatAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
    var tapFormat = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    if AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &formatSize, &tapFormat) == noErr {
        if tapFormat.mSampleRate > 0 { rate = tapFormat.mSampleRate }
        if tapFormat.mChannelsPerFrame > 0 { channels = Int(tapFormat.mChannelsPerFrame) }
    }
    return (newAggregate, rate, channels)
}

/// The audio object ids of processes whose bundle id or name contains `name`.
func processIDs(named name: String) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioObjectID>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, raw) == noErr else { return [] }
    let ids = raw.assumingMemoryBound(to: AudioObjectID.self)
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    let needle = name.lowercased()
    var matches: [AudioObjectID] = []
    for i in 0..<count {
        let id = ids[i]
        var bundleAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var bundleSize = UInt32(MemoryLayout<CFString>.size)
        var bundle: CFString = "?" as CFString
        let ok = withUnsafeMutablePointer(to: &bundle) { ptr in
            AudioObjectGetPropertyData(id, &bundleAddr, 0, nil, &bundleSize, UnsafeMutableRawPointer(ptr)) == noErr
        }
        if ok, (bundle as String).lowercased().contains(needle) {
            matches.append(id)
        }
    }
    return matches
}

/// Opens a capture source and starts pulling samples. Returns the sample rate.
func startCapture(device: AudioDeviceID?, options: Options, source: Source) -> Double {
    var sampleRate: Double
    var channels: Int
    var captureDevice = device

    switch source {
    case .output:
        if #available(macOS 14.2, *) {
            let tap = createOutputTap(excludeApp: options.excludeApp)
            captureDevice = tap.device
            sampleRate = tap.rate
            channels = tap.channels
        } else {
            fail("capturing system output needs macOS 14.2 or later. Use --source input for the microphone.")
        }
    case .input:
        guard let captureDevice else {
            fail("no input device available.")
        }
        sampleRate = nominalSampleRate(captureDevice)
        channels = inputChannelCount(captureDevice)
    }

    var format = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(4 * channels),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(4 * channels),
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32,
        mReserved: 0)

    var queue: AudioQueueRef?
    var status = AudioQueueNewInput(&format, inputCallback, nil, nil, nil, 0, &queue)
    if status != noErr {
        // Fall back to mono if the device refuses the channel count we asked for.
        channels = 1
        format.mChannelsPerFrame = 1
        format.mBytesPerFrame = 4
        format.mBytesPerPacket = 4
        status = AudioQueueNewInput(&format, inputCallback, nil, nil, nil, 0, &queue)
        if status != noErr {
            fail("couldn't open the capture source (AudioQueue error \(status)).")
        }
    }
    guard let q = queue else { fail("couldn't open the capture source.") }
    audioQueue = q

    // For a physical input device, point the queue at it explicitly. The aggregate device that
    // wraps the tap is already the only candidate the queue picks up, so this is a no-op there.
    if source == .input, let captureDevice, let uid = deviceUID(captureDevice) {
        let unmanaged = Unmanaged.passUnretained(uid)
        AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, unmanaged.toOpaque(),
                              UInt32(MemoryLayout<CFString>.size))
    }

    let framesPerBuffer = 1024
    let bytesPerBuffer = UInt32(framesPerBuffer * channels * 4)
    for _ in 0..<3 {
        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBuffer(q, bytesPerBuffer, &buffer) == noErr, let b = buffer else {
            fail("couldn't allocate an audio buffer.")
        }
        AudioQueueEnqueueBuffer(q, b, 0, nil)
    }

    processor.configure(sampleRate: sampleRate, channels: channels,
                        cutoff: options.cutoffHz, highpass: options.highpassHz)

    status = AudioQueueStart(q, nil)
    if status != noErr {
        fail("couldn't start the capture source (AudioQueue error \(status)).")
    }
    return sampleRate
}

func stopCapture() {
    if let q = audioQueue {
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true)
        audioQueue = nil
    }
    if aggregateID != 0 {
        _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = 0
    }
    if tapID != 0 {
        if #available(macOS 14.2, *) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = 0
    }
}

// MARK: - Analysis
//
// Every 25 ms: take the last ~64 ms of filtered audio, measure its level, and find its
// fundamental with normalised autocorrelation. The level becomes the drive strength; the
// fundamental becomes the motor's frequency.

let analysisDecimation = 8

/// Normalised autocorrelation of `x` at one lag: how well the signal repeats after `lag` samples.
func autocorrelationAt(_ x: [Float], _ m: Int, _ lag: Int) -> Double {
    var corr = 0.0, ea = 0.0, eb = 0.0
    for i in 0..<(m - lag) {
        let a = Double(x[i]), b = Double(x[i + lag])
        corr += a * b; ea += a * a; eb += b * b
    }
    return corr / max(sqrt(ea * eb), 1e-12)
}

/// Normalised autocorrelation over a decimated copy of the signal. Returns the fundamental and
/// how periodic the signal is (0 = noise, 1 = a pure tone).
func estimateFundamental(_ samples: [Float], count: Int, sampleRate: Double,
                         minHz: Double, maxHz: Double, scratch: inout [Float]) -> (hz: Double, confidence: Double) {
    let dsr = sampleRate / Double(analysisDecimation)
    let m = count / analysisDecimation
    guard m > 64, scratch.count >= m else { return (0, 0) }

    var mean = 0.0
    for i in 0..<m { mean += Double(samples[i * analysisDecimation]) }
    mean /= Double(m)

    var energy = 0.0
    for i in 0..<m {
        let v = Double(samples[i * analysisDecimation]) - mean
        scratch[i] = Float(v)
        energy += v * v
    }
    guard energy > 1e-12 else { return (0, 0) }

    let minLag = max(2, Int((dsr / maxHz).rounded()))
    let maxLag = min(m - 8, Int((dsr / minHz).rounded()))
    guard maxLag > minLag else { return (0, 0) }

    var bestLag = 0
    var bestR = -1.0
    for lag in minLag...maxLag {
        let r = autocorrelationAt(scratch, m, lag)
        if r > bestR { bestR = r; bestLag = lag }
    }
    guard bestLag > 0, bestR > 0 else { return (0, 0) }

    // Parabolic interpolation for sub-lag precision.
    var refined = Double(bestLag)
    if bestLag > minLag, bestLag < maxLag {
        let previousR = autocorrelationAt(scratch, m, bestLag - 1)
        let nextR = autocorrelationAt(scratch, m, bestLag + 1)
        let denom = previousR - 2 * bestR + nextR
        if abs(denom) > 1e-9 {
            refined += 0.5 * (previousR - nextR) / denom
        }
    }
    let hz = dsr / max(refined, 1.0)
    return (hz, bestR)
}

/// Maps a measured level in dBFS to a drive level (0...1) using the floor / ceiling / gamma / gain
/// curve. Below the floor the signal counts as silence.
func levelForDb(_ db: Double, options: Options) -> Double {
    guard db > options.floorDb else { return 0 }
    let span = options.ceilingDb - options.floorDb
    let norm = min(1.0, max(0.0, (db - options.floorDb) / span))
    return min(pow(norm, options.gamma) * options.gain, options.maxLevel)
}

/// Verifies the filter and the pitch tracker against synthetic signals. Opens no audio device,
/// touches no haptic motor, and makes no sound: it feeds known waveforms through the real
/// filter chain and checks what the analyser reports.
func selfTest(options: Options) -> Never {
    let sampleRate = 48000.0
    let window = 3072
    var decimated = [Float](repeating: 0, count: window / analysisDecimation + 8)

    /// Feeds a synthetic signal through the real filter chain and measures the result.
    func measure(_ label: String, tones: [(hz: Double, amp: Double)]) -> (db: Double, hz: Double, level: Double) {
        let test = InputProcessor()
        test.configure(sampleRate: sampleRate, channels: 1,
                       cutoff: options.cutoffHz, highpass: options.highpassHz)
        let count = Int(sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var v = 0.0
            for tone in tones {
                v += tone.amp * sin(2 * Double.pi * tone.hz * Double(i) / sampleRate)
            }
            samples[i] = Float(v)
        }
        samples.withUnsafeBufferPointer { buf in
            test.process(data: buf.baseAddress!, sampleCount: count)
        }
        var buffer = [Float](repeating: 0, count: window)
        let got = test.ring.copyLast(window, into: &buffer)
        guard got >= window / 2 else { return (-180, 0, 0) }

        var sumSq = 0.0
        for i in 0..<got { let v = Double(buffer[i]); sumSq += v * v }
        let rms = sqrt(sumSq / Double(got))
        let db = 20 * log10(max(rms, 1e-9))
        let level = levelForDb(db, options: options)

        let searchMaxHz = min(400, max(80, options.cutoffHz * 2))
        let (hz, _) = estimateFundamental(buffer, count: got, sampleRate: sampleRate,
                                          minHz: 25, maxHz: searchMaxHz, scratch: &decimated)
        return (db, hz, level)
    }

    print("trackpad-subwoofer — self test")
    print("  (no audio device, no haptic motor, no sound)\n")

    var failures = 0
    func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("  \(ok ? "✓" : "✗") \(message)")
    }

    let low = measure("60", tones: [(60, 0.5)])
    print("  60 Hz sine      -> \(String(format: "%.1f dB", low.db))   f0 \(String(format: "%.1f", low.hz)) Hz   level \(String(format: "%.2f", low.level))")
    check(abs(low.hz - 60) <= 8, "60 Hz is detected as 60 Hz")
    check(low.level > 0.05, "60 Hz produces drive")

    let high = measure("440", tones: [(440, 0.5)])
    print("  440 Hz sine     -> \(String(format: "%.1f dB", high.db))   f0 \(String(format: "%.1f", high.hz)) Hz   level \(String(format: "%.2f", high.level))")
    check(high.db <= low.db - 25, "440 Hz is at least 25 dB down after the low-pass")

    let mixed = measure("mix", tones: [(60, 0.5), (440, 0.5)])
    print("  60 + 440 Hz     -> \(String(format: "%.1f dB", mixed.db))   f0 \(String(format: "%.1f", mixed.hz)) Hz   level \(String(format: "%.2f", mixed.level))")
    check(abs(mixed.hz - 60) <= 10, "the bass is still found when highs are mixed in")

    let quiet = measure("silence", tones: [])
    print("  silence         -> \(String(format: "%.1f dB", quiet.db))   f0 \(String(format: "%.1f", quiet.hz)) Hz   level \(String(format: "%.2f", quiet.level))")
    check(quiet.level == 0, "silence produces no drive")

    let fifty = measure("50", tones: [(50, 0.5)])
    print("  50 Hz sine      -> \(String(format: "%.1f dB", fifty.db))   f0 \(String(format: "%.1f", fifty.hz)) Hz   level \(String(format: "%.2f", fifty.level))")
    check(abs(fifty.hz - 50) <= 8, "50 Hz is detected as 50 Hz")

    // The tone shape the program sends must survive the encoder as a distinct, supported type.
    // This builds actuation OBJECTS only — it never actuates, so nothing moves and no sound.
    // It goes through waveformName(), the same mapping the program uses, so a case bug can't hide.
    print("\n  tone shape encoding (objects only, never actuated):")
    var typeCodes: [String: Int] = [:]
    for shape in ["sine", "square", "sawtooth", "notawaveform"] {
        let sent = waveformName(shape)
        if let code = encodedToneType(sent) {
            typeCodes[shape] = code
            print("    \"\(shape)\" -> sent as \"\(sent)\" -> type code \(code)")
        } else {
            print("    \"\(shape)\" -> sent as \"\(sent)\" -> could not build an actuation")
        }
    }
    check(typeCodes["sine"] == 1, "sine encodes as type code 1")
    check(typeCodes["square"] == 2, "square encodes as type code 2")
    check(typeCodes["sawtooth"] == 3, "sawtooth encodes as type code 3")
    check(typeCodes["notawaveform"] == 1, "an unknown shape falls back to sine, not to a silently wrong one")

    // The encoder's type string is case-sensitive: lowercase silently becomes Gaussian.
    if let lower = encodedToneType("square") {
        check(lower == 0, "a lowercase type string is rejected by the encoder (so the mapping matters)")
    }

    print("\n  \(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")")
    exit(failures == 0 ? 0 : 1)
}

/// Builds an actuation with one tone of the given shape and reads back the encoded type code.
/// Creates the object only — never actuates it, so the trackpad does not move and no sound plays.
func encodedToneType(_ toneType: String) -> Int? {
    guard let actuationCreate else { return nil }
    let shape: [String: Any] = [
        "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": 20.0],
        "Tones": [["Type": toneType, "Amplitude": 1.0, "DurationMS": 20.0,
                    "DelayMS": 0.0, "FrequencykHz": 0.06]],
    ]
    guard let act = actuationCreate(shape as CFDictionary, 0) else { return nil }
    let raw = UnsafeRawPointer(act)
    let code = Int(raw.load(fromByteOffset: 64, as: UInt8.self))
    Unmanaged<AnyObject>.fromOpaque(act).release()
    return code
}

func analysisLoop(sampleRate: Double, options: Options) {
    let window = 3072
    var buffer = [Float](repeating: 0, count: window)
    var decimated = [Float](repeating: 0, count: window / analysisDecimation + 8)
    var smoothedLevel = 0.0
    var smoothedHz = 60.0
    var recentDb: [Double] = []
    var elapsed = 0.0
    var feedbackHoldUntil = 0.0
    var feedbackCooldownUntil = 0.0
    let dt = 0.025

    while !stopRequested {
        elapsed += dt
        let got = processor.ring.copyLast(window, into: &buffer)
        guard got >= window / 2 else { usleep(15_000); continue }

        var sumSq = 0.0
        for i in 0..<got { let v = Double(buffer[i]); sumSq += v * v }
        let rms = sqrt(sumSq / Double(got))
        let db = 20 * log10(max(rms, 1e-9))

        var targetLevel = levelForDb(db, options: options)

        // Track the fundamental, but only when it's clearly there, and slew it rather than jump.
        // The search stops at twice the low-pass corner: above that the filter has already gutted
        // the signal, and looking for a peak there only finds leakage and aliases.
        let searchMaxHz = min(400, max(80, options.cutoffHz * 2))
        let (hz, confidence) = estimateFundamental(buffer, count: got, sampleRate: sampleRate,
                                                   minHz: 25, maxHz: searchMaxHz, scratch: &decimated)
        if confidence >= 0.45 && hz > 0 {
            let target = min(max(hz, options.minDriveHz), options.maxDriveHz)
            let ratio = target / max(smoothedHz, 1)
            let maxRatio = pow(2.0, dt / 0.12)   // at most about an octave every 120 ms
            smoothedHz *= min(max(ratio, 1 / maxRatio), maxRatio)
        }
        smoothedHz = min(max(smoothedHz, options.minDriveHz), options.maxDriveHz)

        // Feedback guard: the trackpad's own rumble can travel back into the microphone that is
        // driving it. A loop is recognisable because the mic ends up hearing a very pure tone
        // (high autocorrelation) sitting exactly on the frequency being driven. Two cases matter:
        //
        //   runaway -- the level is growing, or already very loud. This is the dangerous one: it
        //              can spiral up into a screaming trackpad. Break it by dropping the drive to
        //              zero for 150 ms; the loop dies, then the drive comes back.
        //   hum     -- the level is steady at a moderate value, i.e. the trackpad has settled into
        //              holding a tone. Halve the drive so the loop can't sustain itself.
        //
        // Both need the tone to be locked to the commanded frequency. Real music that happens to
        // sit on that frequency can trip the hum case, which costs a little loudness on that note
        // and nothing more -- much better than a runaway.
        if options.feedbackGuard {
            recentDb.append(db)
            if recentDb.count > 20 { recentDb.removeFirst() }
            let commanded = control.readDrive()
            let locked = commanded.hz > 0
                && confidence >= 0.85
                && abs(hz - commanded.hz) <= commanded.hz * 0.05
            let growth = recentDb.count >= 4 ? db - recentDb[0] : 0
            let runaway = locked && (growth > 5.0 || db > -6.0)
            let hum = locked && recentDb.count >= 16
                && abs(growth) <= options.feedbackDecay && db > -30.0

            if runaway && elapsed >= feedbackCooldownUntil {
                feedbackHoldUntil = elapsed + 0.15
                feedbackCooldownUntil = elapsed + 2.0
            } else if hum && elapsed >= feedbackCooldownUntil {
                targetLevel *= 0.5
                feedbackCooldownUntil = elapsed + 1.5
            }
            if elapsed < feedbackHoldUntil { targetLevel = 0 }
        }

        // Attack fast, release slow -- except when breaking a loop, which has to be immediate.
        let inHold = elapsed < feedbackHoldUntil
        let tau = inHold ? 0.015 : (targetLevel > smoothedLevel ? options.attack : options.release)
        let coeff = 1 - exp(-dt / max(tau, 1e-4))
        smoothedLevel += (targetLevel - smoothedLevel) * coeff

        control.update(level: smoothedLevel, hz: smoothedHz, db: db, confidence: confidence)
        usleep(25_000)
    }
}

// MARK: - Haptic driver
//
// Segments of about 20 ms, each an integer number of cycles of the current drive frequency so the
// sine never starts mid-cycle (that would click). Strength follows the envelope.

func hapticLoop(options: Options) {
    var currentLevel = 0.0
    var meterCounter = 0
    let interactive = isatty(outFD) == 1

    while !stopRequested {
        let state = control.read()
        let target = min(state.level, options.maxLevel)

        if target > 0.015 {
            let hz = min(max(options.fixedHz ?? state.hz, options.minDriveHz), options.maxDriveHz)
            let driveHz = min(max(hz, hardwareMinHz), hardwareMaxHz)
            let cycles = max(1, Int((0.020 * driveHz).rounded()))
            let segmentMs = 1000.0 * Double(cycles) / driveHz
            // Ramp across the segment: drive at the midpoint between last time and now.
            let drive = Float(min(options.maxLevel, max(0, (currentLevel + target) / 2)))
            currentLevel = target
            control.updateDrive(hz: driveHz, level: Double(drive))

            var tones: [(hz: Double, amp: Double)] = [(hz: driveHz, amp: 1.0)]
            if options.harmonic > 0 {
                tones.append((hz: driveHz * Double(options.harmonic), amp: options.harmonicAmp))
            }
            if !options.dryRun {
                actuate(tones: tones, ms: segmentMs, level: drive, waveform: waveformName(options.waveform))
            }
            usleep(useconds_t(max(1000, segmentMs * 1000 - 1200)))
        } else {
            currentLevel = 0
            control.updateDrive(hz: 0, level: 0)
            usleep(12_000)
        }

        if options.showMeter {
            meterCounter += 1
            if meterCounter % 4 == 0 {
                let line = String(format: "  bass %6.1f dB   f0 %5.1f Hz   drive %5.1f Hz   level %.2f   conf %.2f",
                                  state.db, state.hz, options.fixedHz ?? state.hz, state.level, state.confidence)
                if interactive {
                    out(line + "\u{1B}[K\r")
                } else if meterCounter % 40 == 0 {
                    out(line + "\n")
                }
            }
        }
    }
}

// MARK: - Main

let options = parseOptions()

if options.selfTest {
    selfTest(options: options)
}

if options.listDevices {
    let def = defaultInputDevice()
    for id in allDeviceIDs() where hasInputStreams(id) {
        let mark = id == def ? " (default)" : ""
        print("\(id)  \(deviceName(id))\(mark)")
    }
    exit(0)
}

/// Reports what this Mac can do: the haptic path and the audio path. It opens the actuator
/// (which does not move anything) and queries the input device, but captures no audio and
/// never actuates, so it is safe to run anywhere.
if options.check {
    print("trackpad-subwoofer — check\n")

    let symbols: [(String, Bool)] = [
        ("MTDeviceCreateList", createList != nil),
        ("MTDeviceGetDeviceID", getID != nil),
        ("MTDeviceIsBuiltIn", isBuiltIn != nil),
        ("MTActuatorCreateFromDeviceID", actuatorCreate != nil),
        ("MTActuatorOpen", actuatorOpen != nil),
        ("MTActuatorClose", actuatorClose != nil),
        ("MTActuationCreateFromDictionary", actuationCreate != nil),
        ("MTActuationActuate", actuationPlay != nil),
    ]
    let missing = symbols.filter { !$0.1 }.map { $0.0 }
    if missing.isEmpty {
        print("  haptics:  MultitouchSupport ok (all \(symbols.count) functions found)")
    } else {
        print("  haptics:  MultitouchSupport missing \(missing.joined(separator: ", "))")
    }

    if let list = createList?()?.takeRetainedValue() {
        var found = 0
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            guard getID?(dev, &id) == 0 else { continue }
            found += 1
            let kind = (isBuiltIn?(dev) ?? false) ? "built-in" : "external"
            print("  trackpad: \(kind), device id \(id)")
        }
        print("  trackpads found: \(found)")
    } else {
        print("  trackpads found: 0")
    }

    if let inputDevice = resolveInputDevice(options.device) {
        let uid = deviceUID(inputDevice) as String? ?? "?"
        print("  input:    \(deviceName(inputDevice)) [\(uid)]")
        print("  format:   \(nominalSampleRate(inputDevice)) Hz, \(inputChannelCount(inputDevice)) channel(s)")
    } else {
        print("  input:    none — check System Settings > Sound > Input")
    }

    if #available(macOS 14.2, *) {
        print("  output:   system-audio tap available (macOS 14.2+)")
        let running = processList()
        if running.isEmpty {
            print("  apps:     none currently outputting audio")
        } else {
            print("  apps:     \(running.joined(separator: ", "))")
        }
    } else {
        print("  output:   unavailable on this macOS version (needs 14.2+)")
    }
    print("\n  (this check captured no audio and did not move the trackpad)")
    exit(0)
}

/// The bundle ids of apps currently producing audio.
func processList() -> [String] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioObjectID>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, raw) == noErr else { return [] }
    let ids = raw.assumingMemoryBound(to: AudioObjectID.self)
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var names: [String] = []
    for i in 0..<count {
        var bundleAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var bundleSize = UInt32(MemoryLayout<CFString>.size)
        var bundle: CFString = "?" as CFString
        let ok = withUnsafeMutablePointer(to: &bundle) { ptr in
            AudioObjectGetPropertyData(ids[i], &bundleAddr, 0, nil, &bundleSize, UnsafeMutableRawPointer(ptr)) == noErr
        }
        if ok { names.append(bundle as String) }
    }
    return names.sorted()
}

signal(SIGINT) { _ in stopRequested = true }
signal(SIGTERM) { _ in stopRequested = true }
atexit { stopCapture(); unsilence() }

silenceOthers()

motor = openMotor(preferExternal: options.preferExternal)
motorPointer = Unmanaged.passUnretained(motor! as AnyObject).toOpaque()

out("trackpad-subwoofer\n")
if options.dryRun { out("  dry run: analysing only, the trackpad stays still\n") }
switch options.source {
case .output:
    out("  source: system output (everything the Mac is playing)\n")
case .input:
    if let device = resolveInputDevice(options.device) {
        out("  source: microphone — \(deviceName(device))\n")
    } else {
        out("  source: microphone — none found\n")
    }
}
out("  band:   \(options.highpassHz) Hz – \(options.cutoffHz) Hz\n")
out("  motor:  \(options.minDriveHz) Hz – \(options.maxDriveHz) Hz, max level \(options.maxLevel)\n")
if let fixed = options.fixedHz { out("  fixed:  \(fixed) Hz\n") }
if let excluded = options.excludeApp { out("  ignore: \(excluded)\n") }
out("  ctrl-c to stop\n\n")

let sampleRate = startCapture(device: resolveInputDevice(options.device), options: options, source: options.source)

let analysisThread = Thread {
    analysisLoop(sampleRate: sampleRate, options: options)
}
analysisThread.stackSize = 512 * 1024
analysisThread.start()

hapticLoop(options: options)

stopCapture()
if let motor { _ = actuatorClose?(motor) }
unsilence()
out("\nstopped.\n")
