//
//  SleepGuard.swift
//  AgentCord
//
//  Holds an IOKit power assertion that keeps the Mac awake while the user has
//  "Prevent sleep" enabled. We assert against *display* idle sleep, which keeps
//  the screen on (so the Mac never reaches the lock screen) and implicitly keeps
//  the system awake too. The assertion is released the moment the toggle is
//  turned off or the app quits, so it never outlives its purpose.
//

import Foundation
import IOKit.pwr_mgt

final class SleepGuard {

    private var assertionID = IOPMAssertionID(0)
    private var active = false

    /// Mirrors the toggle. Idempotent: re-applying the same value is a no-op, so
    /// it's safe to call on every settings change.
    func setEnabled(_ enabled: Bool) {
        enabled ? acquire() : release()
    }

    private func acquire() {
        guard !active else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "agentcord is keeping your Mac awake" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return }
        assertionID = id
        active = true
    }

    private func release() {
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        active = false
    }

    deinit { release() }
}
