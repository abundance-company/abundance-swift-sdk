import XCTest
@testable import AbundanceSample

final class FirmwareUpdateStateTests: XCTestCase {
    func testDownloadActionDoesNotRequireCameraConnection() {
        XCTAssertEqual(
            selectFirmwareUpdateAction(
                hasRelease: true,
                hasDownloadedBundle: false,
                runsInstalledVersionCheck: false,
                isBusy: false,
                releaseIsInstalled: false
            ),
            .downloadRelease
        )
    }

    func testSendActionDoesNotRequireCameraConnection() {
        XCTAssertEqual(
            selectFirmwareUpdateAction(
                hasRelease: true,
                hasDownloadedBundle: true,
                runsInstalledVersionCheck: false,
                isBusy: false,
                releaseIsInstalled: false
            ),
            .installRelease
        )
    }

    func testInstallWaitOffersManualVersionCheck() {
        XCTAssertEqual(
            selectFirmwareUpdateAction(
                hasRelease: true,
                hasDownloadedBundle: true,
                runsInstalledVersionCheck: true,
                isBusy: false,
                releaseIsInstalled: false
            ),
            .checkInstalledVersion
        )
    }

    func testVersionCheckHidesActionsWhileBusy() {
        XCTAssertEqual(
            selectFirmwareUpdateAction(
                hasRelease: true,
                hasDownloadedBundle: true,
                runsInstalledVersionCheck: true,
                isBusy: true,
                releaseIsInstalled: false
            ),
            .none
        )
    }

    func testInstalledReleaseNeedsNoAction() {
        XCTAssertEqual(
            selectFirmwareUpdateAction(
                hasRelease: true,
                hasDownloadedBundle: true,
                runsInstalledVersionCheck: false,
                isBusy: false,
                releaseIsInstalled: true
            ),
            .none
        )
    }
}
