enum FirmwareUpdateAction: Equatable {
    case checkRelease
    case downloadRelease
    case installRelease
    case checkInstalledVersion
    case none
}

/// The send action stays available without a camera connection: tapping it
/// probes the SoftAP and reports an exact failure instead of hiding.
func selectFirmwareUpdateAction(
    hasRelease: Bool,
    hasDownloadedBundle: Bool,
    runsInstalledVersionCheck: Bool,
    isBusy: Bool,
    releaseIsInstalled: Bool
) -> FirmwareUpdateAction {
    if !hasRelease { return .checkRelease }
    if runsInstalledVersionCheck { return isBusy ? .none : .checkInstalledVersion }
    if releaseIsInstalled { return .none }
    if isBusy { return .none }
    if !hasDownloadedBundle { return .downloadRelease }
    return .installRelease
}
