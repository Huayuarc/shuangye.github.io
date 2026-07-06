import Foundation
import UIKit
import QuartzCore

private let basePCPUFreqs = [600, 972, 1332, 1692, 2052, 2412, 2772, 3000, 3132, 3456, 3780]
private let baseECPUFreqs = [600, 972, 1332, 1692, 2016]
private let lowPowerCeilingMHz = 2016
private let validMinMHz = 100.0
private let validMaxMHz = 4200.0
private let compactFrequencyFontScale: CGFloat = 0.90
private let transientLowJumpThresholdMHz = 1200
private let transientHighReferenceMHz = 1800
private let transientLowJumpConfirmSamples = 3

@objc(CPUthermalFreqCCModuleViewController)
public final class CPUthermalFreqCCModuleViewController: CCUIMenuModuleViewController {
    private var contentView = UIView()
    private var frequencyLabel = UILabel()
    private var refreshTimer: Timer?

    private var lastDisplayedMHz = 0
    private var sampleCount = 0
    private var deviceMaxPCoreMHz = 0
    private var pendingDisplayedMHz = 0
    private var pendingDisplayRepeatCount = 0
    private var pCoreFrequencies = [Int]()
    private var eCoreFrequencies = [Int]()
    private var hasStableReading = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "CPU频率"
        view.backgroundColor = .clear

        useTrailingCheckmarkLayout = false
        useTallLayout = false
        hideGlyphInHeader = false
        if responds(to: NSSelectorFromString("setShouldProvideOwnPlatter:")) {
            setValue(false, forKey: "shouldProvideOwnPlatter")
        }

        sampleCount = 0
        hasStableReading = false
        lastDisplayedMHz = 0
        pendingDisplayedMHz = 0
        pendingDisplayRepeatCount = 0
        deviceMaxPCoreMHz = deviceMaxPCoreFrequencyMHz()
        setupViews()
        refreshFrequency()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCompactLayout()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshFrequency()
        startTimer()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopTimer()
    }

    deinit {
        stopTimer()
    }

    private func setupViews() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .clear
        view.addSubview(contentView)

        frequencyLabel.translatesAutoresizingMaskIntoConstraints = false
        frequencyLabel.textAlignment = .center
        frequencyLabel.textColor = .label
        frequencyLabel.adjustsFontSizeToFitWidth = true
        frequencyLabel.minimumScaleFactor = 0.55
        frequencyLabel.numberOfLines = 1
        frequencyLabel.text = "-- MHz"
        contentView.addSubview(frequencyLabel)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            frequencyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            frequencyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            frequencyLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        updateCompactLayout()
    }

    private func updateCompactLayout() {
        let minSide = min(view.bounds.width, view.bounds.height)
        let fontSize = max(14.0, minSide * compactFrequencyFontScale * 0.32)
        frequencyLabel.font = .systemFont(ofSize: fontSize, weight: .semibold)
    }

    private func startTimer() {
        stopTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshFrequency()
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func hardwareIdentifier() -> String {
        CPUthermalShared.hardwareIdentifier()
    }

    private func isTargetDevice() -> Bool {
        let hardware = hardwareIdentifier()
        return hardware.hasPrefix("iPhone") || hardware.hasPrefix("iPad")
    }

    private func sysctlMaxFrequencyMHz() -> Int {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname("hw.cpufrequency_max", &value, &size, nil, 0) == 0 {
            let mhz = rawValueToMHz(value)
            if mhz >= validMinMHz, mhz <= validMaxMHz {
                return Int(mhz.rounded())
            }
        }
        return 0
    }

    private func deviceMaxPCoreFrequencyMHz() -> Int {
        let native = CPUthermalShared.nativeMaxPCoreFrequencyMHz()
        if native > 0 {
            return native
        }
        let sysctl = sysctlMaxFrequencyMHz()
        return sysctl > 0 ? sysctl : CPUthermalShared.defaultMaxPCoreFrequencyMHz
    }

    private func pCoreFrequencyTable() -> [Int] {
        if !pCoreFrequencies.isEmpty {
            return pCoreFrequencies
        }
        let maxFrequency = deviceMaxPCoreMHz > 0 ? deviceMaxPCoreMHz : CPUthermalShared.defaultMaxPCoreFrequencyMHz
        var freqs = basePCPUFreqs.filter { $0 <= maxFrequency + 30 }
        if !freqs.contains(maxFrequency) {
            freqs.append(maxFrequency)
        }
        freqs = Array(Set(freqs)).sorted()
        pCoreFrequencies = freqs
        return freqs
    }

    private func eCoreFrequencyTable() -> [Int] {
        if eCoreFrequencies.isEmpty {
            eCoreFrequencies = baseECPUFreqs
        }
        return eCoreFrequencies
    }

    private func isLowPowerModeActive() -> Bool {
        CPUthermalShared.currentPowerMode() == "lowPower"
    }

    private func stableDisplayMHz(for reading: Int) -> Int {
        var displayMHz = snapToPState(reading)
        if isLowPowerModeActive(), displayMHz > lowPowerCeilingMHz {
            displayMHz = lowPowerCeilingMHz
        }

        sampleCount += 1
        if !hasStableReading {
            hasStableReading = sampleCount >= 2
            lastDisplayedMHz = displayMHz
            return displayMHz
        }

        if lastDisplayedMHz >= transientHighReferenceMHz,
           displayMHz <= transientLowJumpThresholdMHz,
           displayMHz < lastDisplayedMHz {
            if pendingDisplayedMHz == displayMHz {
                pendingDisplayRepeatCount += 1
            } else {
                pendingDisplayedMHz = displayMHz
                pendingDisplayRepeatCount = 1
            }
            if pendingDisplayRepeatCount < transientLowJumpConfirmSamples {
                return lastDisplayedMHz
            }
        } else {
            pendingDisplayedMHz = 0
            pendingDisplayRepeatCount = 0
        }

        lastDisplayedMHz = displayMHz
        return displayMHz
    }

    @objc private func refreshFrequency() {
        guard isTargetDevice() else {
            frequencyLabel.text = "不支持"
            return
        }

        let reading = readCurrentFrequencyMHz()
        if reading >= validMinMHz, reading <= validMaxMHz {
            let displayMHz = stableDisplayMHz(for: Int(reading.rounded()))
            frequencyLabel.text = "\(displayMHz) MHz"
            frequencyLabel.textColor = isLowPowerModeActive() ? .systemGreen : .label
        } else {
            frequencyLabel.text = "-- MHz"
            frequencyLabel.textColor = .secondaryLabel
        }
    }

    private func snapToPState(_ mhz: Int) -> Int {
        let table = pCoreFrequencyTable()
        guard !table.isEmpty else { return mhz }
        var best = table[0]
        var bestDelta = abs(mhz - best)
        for value in table.dropFirst() {
            let delta = abs(mhz - value)
            if delta < bestDelta {
                best = value
                bestDelta = delta
            }
        }
        return best
    }

    private func readCurrentFrequencyMHz() -> Double {
        let clpc = clpcFrequencyFromIOKit()
        if clpc >= validMinMHz { return clpc }

        let sysctl = sysctlFrequencyMHz()
        if sysctl >= validMinMHz { return sysctl }

        let modeLimited = isLowPowerModeActive() ? Double(lowPowerCeilingMHz) : Double(deviceMaxPCoreMHz)
        return modeLimited > 0 ? modeLimited : 0.0
    }

    private func clpcFrequencyFromIOKit() -> Double {
        let serviceNames = ["AppleCLPC", "clpc", "ApplePPM", "ppm", "pmu"]
        let freqKeys = [
            "CPUFrequency",
            "CPU Frequency",
            "current-frequency",
            "current-cpu-frequency",
            "cpu-current-frequency",
            "cpu-frequency",
            "frequency",
            "freq",
            "AETS p-limited mhz",
            "AETS e-limited mhz"
        ]

        for serviceName in serviceNames {
            guard let matching = IOServiceNameMatching(serviceName) else { continue }
            let service = IOServiceGetMatchingService(kIOMasterPortDefault, matching.takeRetainedValue())
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }

            for key in freqKeys {
                guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
                    continue
                }
                let mhz = extractMHz(from: value)
                if mhz >= validMinMHz, mhz <= validMaxMHz {
                    return mhz
                }
            }
        }
        return 0.0
    }

    private func extractMHz(from object: Any) -> Double {
        if let number = object as? NSNumber {
            return rawValueToMHz(number.int64Value)
        }
        if let data = object as? Data {
            if data.count >= 8 {
                let value = data.withUnsafeBytes { $0.load(as: UInt64.self) }
                let mhz = rawValueToMHz(Int64(bitPattern: value))
                if mhz >= validMinMHz { return mhz }
            }
            if data.count >= 4 {
                let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
                return rawValueToMHz(Int64(value))
            }
        }
        if let array = object as? [Any] {
            for item in array {
                let mhz = extractMHz(from: item)
                if mhz >= validMinMHz { return mhz }
            }
        }
        if let dict = object as? [AnyHashable: Any] {
            for value in dict.values {
                let mhz = extractMHz(from: value)
                if mhz >= validMinMHz { return mhz }
            }
        }
        return 0.0
    }

    private func rawValueToMHz(_ value: Int64) -> Double {
        guard value > 0 else { return 0.0 }
        var mhz = Double(value)
        if mhz >= 1_000_000_000.0 {
            mhz /= 1_000_000.0
        } else if mhz >= 1_000_000.0 {
            mhz /= 1_000.0
        }
        return (mhz >= validMinMHz && mhz <= validMaxMHz) ? mhz : 0.0
    }

    private func sysctlFrequencyMHz() -> Double {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname("hw.cpufrequency", &value, &size, nil, 0) == 0 {
            let mhz = rawValueToMHz(value)
            if mhz >= validMinMHz { return mhz }
        }
        if sysctlbyname("hw.cpufrequency_max", &value, &size, nil, 0) == 0 {
            let mhz = rawValueToMHz(value)
            if mhz >= validMinMHz { return mhz }
        }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        if timebase.denom > 0, timebase.numer > 0 {
            let timebaseFrequency = 1_000_000_000.0 * Double(timebase.denom) / Double(timebase.numer)
            if timebaseFrequency > 20_000_000.0, timebaseFrequency < 30_000_000.0 {
                return 0.0
            }
        }
        return 0.0
    }

    @objc public override func preferredExpandedContentHeight() -> CGFloat {
        214.0
    }

    @objc public override func preferredExpandedContentWidth() -> CGFloat {
        280.0
    }

    @objc public override func providesOwnPlatter() -> Bool {
        false
    }

    @objc public override func shouldBeginTransitionToExpandedContentModule() -> Bool {
        false
    }

    @objc public func _toggleModuleExpanded() -> Bool {
        false
    }

    @objc public override func buttonTapped(_ arg: Any?, forEvent event: Any?) {
        refreshFrequency()
        if !hasStableReading {
            sampleCount = 0
        }
    }
}
