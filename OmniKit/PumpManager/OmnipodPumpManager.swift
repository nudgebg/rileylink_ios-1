//
//  OmnipodPumpManager.swift
//  OmniKit
//
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import HealthKit
import LoopKit
import RileyLinkKit
import RileyLinkBLEKit
import UserNotifications
import os.log

fileprivate let tempBasalConfirmationBeeps: Bool = false // whether to emit temp basal confirmation beeps (for testing use)


public enum ReservoirAlertState {
    case ok
    case lowReservoir
    case empty
}

public protocol PodStateObserver: class {
    func podStateDidUpdate(_ state: PodState?)
}

public enum OmnipodPumpManagerError: Error {
    case noPodPaired
    case podAlreadyPaired
    case podAlreadyPrimed
    case notReadyForPrime
    case notReadyForCannulaInsertion
}

extension OmnipodPumpManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("No pod paired", comment: "Error message shown when no pod is paired")
        case .podAlreadyPrimed:
            return LocalizedString("Pod already primed", comment: "Error message shown when prime is attempted, but pod is already primed")
        case .podAlreadyPaired:
            return LocalizedString("Pod already paired", comment: "Error message shown when user cannot pair because pod is already paired")
        case .notReadyForPrime:
            return LocalizedString("Pod is not in a state ready for priming.", comment: "Error message when prime fails because the pod is in an unexpected state")
        case .notReadyForCannulaInsertion:
            return LocalizedString("Pod is not in a state ready for cannula insertion.", comment: "Error message when cannula insertion fails because the pod is in an unexpected state")
        }
    }
    
    public var failureReason: String? {
        switch self {
        case .noPodPaired:
            return nil
        case .podAlreadyPrimed:
            return nil
        case .podAlreadyPaired:
            return nil
        case .notReadyForPrime:
            return nil
        case .notReadyForCannulaInsertion:
            return nil
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("Please pair a new pod", comment: "Recover suggestion shown when no pod is paired")
        case .podAlreadyPrimed:
            return nil
        case .podAlreadyPaired:
            return nil
        case .notReadyForPrime:
            return nil
        case .notReadyForCannulaInsertion:
            return nil
        }
    }
}

public class OmnipodPumpManager: RileyLinkPumpManager {
    public init(state: OmnipodPumpManagerState, rileyLinkDeviceProvider: RileyLinkDeviceProvider, rileyLinkConnectionManager: RileyLinkConnectionManager? = nil) {
        self.lockedState = Locked(state)
        self.lockedPodComms = Locked(PodComms(podState: state.podState))
        super.init(rileyLinkDeviceProvider: rileyLinkDeviceProvider, rileyLinkConnectionManager: rileyLinkConnectionManager)

        self.podComms.delegate = self
        self.podComms.messageLogger = self
    }

    public required convenience init?(rawState: PumpManager.RawStateValue) {
        guard let state = OmnipodPumpManagerState(rawValue: rawState),
            let connectionManagerState = state.rileyLinkConnectionManagerState else
        {
            return nil
        }

        let rileyLinkConnectionManager = RileyLinkConnectionManager(state: connectionManagerState)

        self.init(state: state, rileyLinkDeviceProvider: rileyLinkConnectionManager.deviceProvider, rileyLinkConnectionManager: rileyLinkConnectionManager)

        rileyLinkConnectionManager.delegate = self
    }

    private var podComms: PodComms {
        get {
            return lockedPodComms.value
        }
        set {
            lockedPodComms.value = newValue
        }
    }
    private let lockedPodComms: Locked<PodComms>

    private let podStateObservers = WeakSynchronizedSet<PodStateObserver>()

    public var state: OmnipodPumpManagerState {
        return lockedState.value
    }

    private func setState(_ changes: (_ state: inout OmnipodPumpManagerState) -> Void) -> Void {
        return setStateWithResult(changes)
    }

    private func mutateState(_ changes: (_ state: inout OmnipodPumpManagerState) -> Void) -> OmnipodPumpManagerState {
        return setStateWithResult({ (state) -> OmnipodPumpManagerState in
            changes(&state)
            return state
        })
    }

    private func setStateWithResult<ReturnType>(_ changes: (_ state: inout OmnipodPumpManagerState) -> ReturnType) -> ReturnType {
        var oldValue: OmnipodPumpManagerState!
        var returnType: ReturnType!
        let newValue = lockedState.mutate { (state) in
            oldValue = state
            returnType = changes(&state)
        }

        guard oldValue != newValue else {
            return returnType
        }

        if oldValue.podState != newValue.podState {
            podStateObservers.forEach { (observer) in
                observer.podStateDidUpdate(newValue.podState)
            }

            if oldValue.podState?.lastInsulinMeasurements?.reservoirLevel != newValue.podState?.lastInsulinMeasurements?.reservoirLevel {
                if let lastInsulinMeasurements = newValue.podState?.lastInsulinMeasurements, let reservoirLevel = lastInsulinMeasurements.reservoirLevel {
                    self.pumpDelegate.notify({ (delegate) in
                        self.log.info("DU: updating reservoir level %{public}@", String(describing: reservoirLevel))
                        delegate?.pumpManager(self, didReadReservoirValue: reservoirLevel, at: lastInsulinMeasurements.validTime) { _ in }
                    })
                }
            }
        }


        // Ideally we ensure that oldValue.rawValue != newValue.rawValue, but the types aren't
        // defined as equatable
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManagerDidUpdateState(self)
        }

        let oldStatus = status(for: oldValue)
        let newStatus = status(for: newValue)

        if oldStatus != newStatus {
            notifyStatusObservers(oldStatus: oldStatus)
        }

        // Reschedule expiration notification if relevant values change
        if oldValue.expirationReminderDate != newValue.expirationReminderDate ||
            oldValue.podState?.expiresAt != newValue.podState?.expiresAt
        {
            schedulePodExpirationNotification(for: newValue)
        }

        return returnType
    }
    private let lockedState: Locked<OmnipodPumpManagerState>

    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    private func notifyStatusObservers(oldStatus: PumpManagerStatus) {
        let status = self.status
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
        statusObservers.forEach { (observer) in
            observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
    }
    
    private func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        var podAddress = "noPod"
        if let podState = self.state.podState {
            podAddress = String(format:"%04X", podState.address)
        }
        self.pumpDelegate.notify { (delegate) in
            delegate?.deviceManager(self, logEventForDeviceIdentifier: podAddress, type: type, message: message, completion: nil)
        }
    }

    private let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()

    public let log = OSLog(category: "OmnipodPumpManager")
    
    private var lastLoopRecommendation: Date?

    // MARK: - RileyLink Updates

    override public var rileyLinkConnectionManagerState: RileyLinkConnectionManagerState? {
        get {
            return state.rileyLinkConnectionManagerState
        }
        set {
            setState { (state) in
                state.rileyLinkConnectionManagerState = newValue
            }
        }
    }

    override public func deviceTimerDidTick(_ device: RileyLinkDevice) {
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManagerBLEHeartbeatDidFire(self)
        }
    }

    // MARK: - CustomDebugStringConvertible

    override public var debugDescription: String {
        let lines = [
            "## OmnipodPumpManager",
            "podComms: \(String(reflecting: podComms))",
            "state: \(String(reflecting: state))",
            "status: \(String(describing: status))",
            "podStateObservers.count: \(podStateObservers.cleanupDeallocatedElements().count)",
            "statusObservers.count: \(statusObservers.cleanupDeallocatedElements().count)",
            super.debugDescription,
        ]
        return lines.joined(separator: "\n")
    }
}

extension OmnipodPumpManager {
    // MARK: - PodStateObserver
    
    public func addPodStateObserver(_ observer: PodStateObserver, queue: DispatchQueue) {
        podStateObservers.insert(observer, queue: queue)
    }
    
    public func removePodStateObserver(_ observer: PodStateObserver) {
        podStateObservers.removeElement(observer)
    }

    private func updateBLEHeartbeatPreference() {
        dispatchPrecondition(condition: .notOnQueue(delegateQueue))

        rileyLinkDeviceProvider.timerTickEnabled = self.state.isPumpDataStale || pumpDelegate.call({ (delegate) -> Bool in
            return delegate?.pumpManagerMustProvideBLEHeartbeat(self) == true
        })
    }

    private func status(for state: OmnipodPumpManagerState) -> PumpManagerStatus {
        return PumpManagerStatus(
            timeZone: state.timeZone,
            device: device(for: state),
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: basalDeliveryState(for: state),
            bolusState: bolusState(for: state)
        )
    }

    private func device(for state: OmnipodPumpManagerState) -> HKDevice {
        if let podState = state.podState {
            return HKDevice(
                name: type(of: self).managerIdentifier,
                manufacturer: "Insulet",
                model: "Eros",
                hardwareVersion: nil,
                firmwareVersion: podState.piVersion,
                softwareVersion: String(OmniKitVersionNumber),
                localIdentifier: String(format:"%04X", podState.address),
                udiDeviceIdentifier: nil
            )
        } else {
            return HKDevice(
                name: type(of: self).managerIdentifier,
                manufacturer: "Insulet",
                model: "Eros",
                hardwareVersion: nil,
                firmwareVersion: nil,
                softwareVersion: String(OmniKitVersionNumber),
                localIdentifier: nil,
                udiDeviceIdentifier: nil
            )
        }
    }

    private func basalDeliveryState(for state: OmnipodPumpManagerState) -> PumpManagerStatus.BasalDeliveryState {
        guard let podState = state.podState else {
            return .suspended(state.lastPumpDataReportDate ?? .distantPast)
        }

        switch state.suspendEngageState {
        case .engaging:
            return .suspending
        case .disengaging:
            return .resuming
        case .stable:
            break
        }

        switch state.tempBasalEngageState {
        case .engaging:
            return .initiatingTempBasal
        case .disengaging:
            return .cancelingTempBasal
        case .stable:
            if let tempBasal = podState.unfinalizedTempBasal, !tempBasal.isFinished {
                return .tempBasal(DoseEntry(tempBasal))
            }
            switch podState.suspendState {
            case .resumed(let date):
                return .active(date)
            case .suspended(let date):
                return .suspended(date)
            }
        }
    }

    private func bolusState(for state: OmnipodPumpManagerState) -> PumpManagerStatus.BolusState {
        guard let podState = state.podState else {
            return .none
        }

        switch state.bolusEngageState {
        case .engaging:
            return .initiating
        case .disengaging:
            return .canceling
        case .stable:
            if let bolus = podState.unfinalizedBolus, !bolus.isFinished {
                return .inProgress(DoseEntry(bolus))
            }
        }
        return .none
    }

    // Thread-safe
    public var hasActivePod: Bool {
        // TODO: Should this check be done automatically before each session?
        return state.hasActivePod
    }

    // Thread-safe
    public var hasSetupPod: Bool {
        return state.hasSetupPod
    }

    // Thread-safe
    public var expirationReminderDate: Date? {
        get {
            return state.expirationReminderDate
        }
        set {
            // Setting a new value reschedules notifications
            setState { (state) in
                state.expirationReminderDate = newValue
            }
        }
    }

    // Thread-safe
    public var confirmationBeeps: Bool {
        get {
            return state.confirmationBeeps
        }
        set {
            setState { (state) in
                state.confirmationBeeps = newValue
            }
        }
    }

    // MARK: - Notifications

    static let podExpirationNotificationIdentifier = "Omnipod:\(LoopNotificationCategory.pumpExpired.rawValue)"

    func schedulePodExpirationNotification(for state: OmnipodPumpManagerState) {
        guard let expirationReminderDate = state.expirationReminderDate,
            expirationReminderDate.timeIntervalSinceNow > 0,
            let expiresAt = state.podState?.expiresAt
        else {
            pumpDelegate.notify { (delegate) in
                delegate?.clearNotification(for: self, identifier: OmnipodPumpManager.podExpirationNotificationIdentifier)
            }
            return
        }

        let content = UNMutableNotificationContent()

        let timeBetweenNoticeAndExpiration = expiresAt.timeIntervalSince(expirationReminderDate)

        let formatter = DateComponentsFormatter()
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full

        let timeUntilExpiration = formatter.string(from: timeBetweenNoticeAndExpiration) ?? ""

        content.title = NSLocalizedString("Pod Expiration Notice", comment: "The title for pod expiration notification")

        content.body = String(format: NSLocalizedString("Time to replace your pod! Your pod will expire in %1$@", comment: "The format string for pod expiration notification body (1: time until expiration)"), timeUntilExpiration)
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = LoopNotificationCategory.pumpExpired.rawValue
        content.threadIdentifier = LoopNotificationCategory.pumpExpired.rawValue

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: expirationReminderDate.timeIntervalSinceNow,
            repeats: false
        )

        pumpDelegate.notify { (delegate) in
            delegate?.scheduleNotification(for: self, identifier: OmnipodPumpManager.podExpirationNotificationIdentifier, content: content, trigger: trigger)
        }
    }

    // MARK: - Pod comms

    // Does not support concurrent callers. Not thread-safe.
    private func forgetPod(completion: @escaping () -> Void) {
        let resetPodState = { (_ state: inout OmnipodPumpManagerState) in
            self.podComms = PodComms(podState: nil)
            self.podComms.delegate = self
            self.podComms.messageLogger = self

            state.podState = nil
            state.expirationReminderDate = nil
        }

        // TODO: PodState shouldn't be mutated outside of the session queue
        // TODO: Consider serializing the entire forget-pod path instead of relying on the UI to do it

        let state = mutateState { (state) in
            state.podState?.finalizeFinishedDoses()
        }

        if let dosesToStore = state.podState?.dosesToStore {
            store(doses: dosesToStore, completion: { error in
                self.setState({ (state) in
                    if error != nil {
                        state.unstoredDoses.append(contentsOf: dosesToStore)
                    }

                    resetPodState(&state)
                })
                completion()
            })
        } else {
            setState { (state) in
                resetPodState(&state)
            }

            completion()
        }
    }
    
    // MARK: Testing
    #if targetEnvironment(simulator)
    private func jumpStartPod(address: UInt32, lot: UInt32, tid: UInt32, fault: DetailedStatus? = nil, startDate: Date? = nil, mockFault: Bool) {
        let start = startDate ?? Date()
        var podState = PodState(address: address, piVersion: "jumpstarted", pmVersion: "jumpstarted", lot: lot, tid: tid)
        podState.setupProgress = .podConfigured
        podState.activatedAt = start
        podState.expiresAt = start + .hours(72)
        
        let fault = mockFault ? try? DetailedStatus(encodedData: Data(hexadecimalString: "020d0000000e00c36a020703ff020900002899080082")!) : nil
        podState.fault = fault

        self.podComms = PodComms(podState: podState)

        setState({ (state) in
            state.podState = podState
            state.expirationReminderDate = start + .hours(70)
        })
    }
    #endif
    
    // MARK: - Pairing

    // Called on the main thread
    public func pairAndPrime(completion: @escaping (PumpManagerResult<TimeInterval>) -> Void) {
        #if targetEnvironment(simulator)
        // If we're in the simulator, create a mock PodState
        let mockFaultDuringPairing = false
        let mockCommsErrorDuringPairing = true
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {
            self.jumpStartPod(address: 0x1f0b3557, lot: 40505, tid: 6439, mockFault: mockFaultDuringPairing)
            let fault: DetailedStatus? = self.setStateWithResult({ (state) in
                state.podState?.setupProgress = .priming
                return state.podState?.fault
            })
            if mockFaultDuringPairing {
                completion(.failure(PodCommsError.podFault(fault: fault!)))
            } else if mockCommsErrorDuringPairing {
                completion(.failure(PodCommsError.noResponse))
            } else {
                let mockPrimeDuration = TimeInterval(.seconds(3))
                completion(.success(mockPrimeDuration))
            }
        }
        #else
        let deviceSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        let configureAndPrimeSession = { (result: PodComms.SessionRunResult) in
            switch result {
            case .success(let session):
                // We're on the session queue
                session.assertOnSessionQueue()

                self.log.default("Beginning pod configuration and prime")

                // Clean up any previously un-stored doses if needed
                let unstoredDoses = self.state.unstoredDoses
                if self.store(doses: unstoredDoses, in: session) {
                    self.setState({ (state) in
                        state.unstoredDoses.removeAll()
                    })
                }

                do {
                    let primeFinishedAt = try session.prime()
                    completion(.success(primeFinishedAt))
                } catch let error {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }

        let needsPairing = setStateWithResult({ (state) -> PumpManagerResult<Bool> in
            guard let podState = state.podState else {
                return .success(true) // Needs pairing
            }

            guard podState.setupProgress.primingNeeded else {
                return .failure(OmnipodPumpManagerError.podAlreadyPrimed)
            }

            // If still need configuring, run pair()
            return .success(podState.setupProgress == .addressAssigned)
        })

        switch needsPairing {
        case .success(true):
            self.log.default("Pairing pod before priming")
            
            // Create random address with 20 bits to match PDM, could easily use 24 bits instead
            if self.state.pairingAttemptAddress == nil {
                self.lockedState.mutate { (state) in
                    state.pairingAttemptAddress = 0x1f000000 | (arc4random() & 0x000fffff)
                }
            }

            self.podComms.assignAddressAndSetupPod(address: self.state.pairingAttemptAddress!, using: deviceSelector, timeZone: .currentFixed, messageLogger: self) { (result) in
                
                if case .success = result {
                    self.lockedState.mutate { (state) in
                        state.pairingAttemptAddress = nil
                    }
                }
                
                // Calls completion
                configureAndPrimeSession(result)
            }
        case .success(false):
            self.log.default("Pod already paired. Continuing.")

            self.podComms.runSession(withName: "Configure and prime pod", using: deviceSelector) { (result) in
                // Calls completion
                configureAndPrimeSession(result)
            }
        case .failure(let error):
            completion(.failure(error))
        }
        #endif
    }

    // Called on the main thread
    public func insertCannula(completion: @escaping (PumpManagerResult<TimeInterval>) -> Void) {
        #if targetEnvironment(simulator)
        let mockDelay = TimeInterval(seconds: 3)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + mockDelay) {
            let result = self.setStateWithResult({ (state) -> PumpManagerResult<TimeInterval> in
                // Mock fault
                //            let fault = try! DetailedStatus(encodedData: Data(hexadecimalString: "020d0000000e00c36a020703ff020900002899080082")!)
                //            self.state.podState?.fault = fault
                //            return .failure(PodCommsError.podFault(fault: fault))

                // Mock success
                state.podState?.setupProgress = .completed
                return .success(mockDelay)
            })

            completion(result)
        }
        #else
        let preError = setStateWithResult({ (state) -> OmnipodPumpManagerError? in
            guard let podState = state.podState, let expiresAt = podState.expiresAt, podState.readyForCannulaInsertion else
            {
                return .notReadyForCannulaInsertion
            }

            state.expirationReminderDate = expiresAt.addingTimeInterval(-Pod.expirationReminderAlertDefaultTimeBeforeExpiration)

            guard podState.setupProgress.needsCannulaInsertion else {
                return .podAlreadyPaired
            }

            return nil
        })

        if let error = preError {
            completion(.failure(error))
            return
        }

        let deviceSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        let timeZone = self.state.timeZone

        self.podComms.runSession(withName: "Insert cannula", using: deviceSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    if self.state.podState?.setupProgress.needsInitialBasalSchedule == true {
                        let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                        try session.programInitialBasalSchedule(self.state.basalSchedule, scheduleOffset: scheduleOffset)

                        session.dosesForStorage() { (doses) -> Bool in
                            return self.store(doses: doses, in: session)
                        }
                    }

                    let finishWait = try session.insertCannula()

                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + finishWait) {
                        // Runs a new session
                        self.checkCannulaInsertionFinished()
                    }
                    completion(.success(finishWait))
                } catch let error {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
        #endif
    }

    private func emitConfirmationBeep(session: PodCommsSession, beepConfigType: BeepConfigType) {
        if self.confirmationBeeps {
            let _ = session.beepConfig(beepConfigType: beepConfigType, basalCompletionBeep: true, tempBasalCompletionBeep: tempBasalConfirmationBeeps, bolusCompletionBeep: true)
        }
    }

    public func checkCannulaInsertionFinished() {
        let deviceSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Check cannula insertion finished", using: deviceSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.checkInsertionCompleted()
                } catch let error {
                    self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
                }
            case .failure(let error):
                self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
            }
        }
    }

    public func refreshStatus(completion: ((_ result: PumpManagerResult<StatusResponse>) -> Void)? = nil) {
        guard self.hasActivePod else {
            completion?(.failure(OmnipodPumpManagerError.noPodPaired))
            return
        }

        self.getPodStatus(storeDosesOnSuccess: false, completion: completion)
    }

    // MARK: - Pump Commands

    private func getPodStatus(storeDosesOnSuccess: Bool, completion: ((_ result: PumpManagerResult<StatusResponse>) -> Void)? = nil) {
        guard state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished != false else {
            self.log.info("Skipping status request due to unfinalized bolus in progress.")
            completion?(.failure(PodCommsError.unfinalizedBolus))
            return
        }
        
        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        podComms.runSession(withName: "Get pod status", using: rileyLinkSelector) { (result) in
            do {
                switch result {
                case .success(let session):
                    let status = try session.getStatus()
                    if storeDosesOnSuccess {
                        session.dosesForStorage({ (doses) -> Bool in
                            self.store(doses: doses, in: session)
                        })
                    }
                    completion?(.success(status))
                case .failure(let error):
                    throw error
                }
            } catch let error {
                completion?(.failure(error))
                self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
            }
        }
    }

    public func acknowledgeAlerts(_ alertsToAcknowledge: AlertSet, completion: @escaping (_ alerts: [AlertSlot: PodAlert]?) -> Void) {
        guard self.hasActivePod else {
            completion(nil)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Acknowledge Alarms", using: rileyLinkSelector) { (result) in
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure:
                completion(nil)
                return
            }

            do {
                let alerts = try session.acknowledgeAlerts(alerts: alertsToAcknowledge)
                self.emitConfirmationBeep(session: session, beepConfigType: .bipBip)
                completion(alerts)
            } catch {
                completion(nil)
            }
        }
    }

    public func setTime(completion: @escaping (Error?) -> Void) {
        
        let timeZone = TimeZone.currentFixed

        let preError = setStateWithResult { (state) -> Error? in
            guard state.hasActivePod else {
                return OmnipodPumpManagerError.noPodPaired
            }

            guard state.podState?.unfinalizedBolus?.isFinished != false else {
                return PodCommsError.unfinalizedBolus
            }

            return nil
        }

        if let error = preError {
            completion(error)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Set time zone", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    let beep = self.confirmationBeeps
                    let _ = try session.setTime(timeZone: timeZone, basalSchedule: self.state.basalSchedule, date: Date(), acknowledgementBeep: beep, completionBeep: beep)
                    self.setState { (state) in
                        state.timeZone = timeZone
                    }
                    completion(nil)
                } catch let error {
                    completion(error)
                }
            case .failure(let error):
                completion(error)
            }
        }
    }

    public func setBasalSchedule(_ schedule: BasalSchedule, completion: @escaping (Error?) -> Void) {
        let shouldContinue = setStateWithResult({ (state) -> PumpManagerResult<Bool> in
            guard state.hasActivePod else {
                // If there's no active pod yet, save the basal schedule anyway
                state.basalSchedule = schedule
                return .success(false)
            }

            guard state.podState?.unfinalizedBolus?.isFinished != false else {
                return .failure(PodCommsError.unfinalizedBolus)
            }

            return .success(true)
        })

        switch shouldContinue {
        case .success(true):
            break
        case .success(false):
            completion(nil)
            return
        case .failure(let error):
            completion(error)
            return
        }

        let timeZone = self.state.timeZone

        self.podComms.runSession(withName: "Save Basal Profile", using: self.rileyLinkDeviceProvider.firstConnectedDevice) { (result) in
            do {
                switch result {
                case .success(let session):
                    let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                    let result = session.cancelDelivery(deliveryType: .all, beepType: .noBeep)
                    switch result {
                    case .certainFailure(let error):
                        throw error
                    case .uncertainFailure(let error):
                        throw error
                    case .success:
                        break
                    }
                    let beep = self.confirmationBeeps
                    let _ = try session.setBasalSchedule(schedule: schedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)

                    self.setState { (state) in
                        state.basalSchedule = schedule
                    }
                    completion(nil)
                case .failure(let error):
                    throw error
                }
            } catch let error {
                self.log.error("Save basal profile failed: %{public}@", String(describing: error))
                completion(error)
            }
        }
    }

    // Called on the main thread.
    // The UI is responsible for serializing calls to this method;
    // it does not handle concurrent calls.
    public func deactivatePod(forgetPodOnFail: Bool, completion: @escaping (Error?) -> Void) {
        #if targetEnvironment(simulator)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {

            self.forgetPod(completion: {
                completion(nil)
            })
        }
        #else
        guard self.state.podState != nil else {
            if forgetPodOnFail {
                forgetPod(completion: {
                    completion(OmnipodPumpManagerError.noPodPaired)
                })
            } else {
                completion(OmnipodPumpManagerError.noPodPaired)
            }
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Deactivate pod", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.deactivatePod()

                    self.forgetPod(completion: {
                        completion(nil)
                    })
                } catch let error {
                    if forgetPodOnFail {
                        self.forgetPod(completion: {
                            completion(error)
                        })
                    } else {
                        completion(error)
                    }
                }
            case .failure(let error):
                if forgetPodOnFail {
                    self.forgetPod(completion: {
                        completion(error)
                    })
                } else {
                    completion(error)
                }
            }
        }
        #endif
    }

    public func readPodStatus(completion: @escaping (Result<DetailedStatus, Error>) -> Void) {
        // use hasSetupPod to be able to read pod info from a faulted Pod
        guard self.hasSetupPod else {
            completion(.failure(PodCommsError.noPodPaired))
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        podComms.runSession(withName: "Read pod status", using: rileyLinkSelector) { (result) in
            do {
                switch result {
                case .success(let session):
                    let detailedStatus = try session.getDetailedStatus()
                    self.emitConfirmationBeep(session: session, beepConfigType: .bipBip)
                    session.dosesForStorage({ (doses) -> Bool in
                        self.store(doses: doses, in: session)
                    })
                    completion(.success(detailedStatus))
                case .failure(let error):
                    completion(.failure(error))
                }
            } catch let error {
                completion(.failure(error))
            }
        }
    }

    public func testingCommands(completion: @escaping (Error?) -> Void) {
        // use hasSetupPod so the user can see any fault info and post fault commands can be attempted
        guard self.hasSetupPod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Testing Commands", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.testingCommands()
                    self.emitConfirmationBeep(session: session, beepConfigType: .beepBeepBeep)
                    completion(nil)
                } catch let error {
                    completion(error)
                }
            case .failure(let error):
                completion(error)
            }
        }
    }

    public func playTestBeeps(completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }
        guard self.state.podState?.unfinalizedBolus?.isFinished != false else {
            self.log.info("Skipping Play Test Beeps due to bolus still in progress.")
            completion(PodCommsError.unfinalizedBolus)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Play Test Beeps", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                let basalCompletionBeep = self.confirmationBeeps
                let tempBasalCompletionBeep = self.confirmationBeeps && tempBasalConfirmationBeeps
                let bolusCompletionBeep = self.confirmationBeeps
                let result = session.beepConfig(beepConfigType: .bipBeepBipBeepBipBeepBipBeep, basalCompletionBeep: basalCompletionBeep, tempBasalCompletionBeep: tempBasalCompletionBeep, bolusCompletionBeep: bolusCompletionBeep)
                
                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            case .failure(let error):
                completion(error)
            }
        }
    }

    public func readPulseLog(completion: @escaping (String) -> Void) {
        // use hasSetupPod to be able to read the pulse log from a faulted Pod
        guard self.hasSetupPod else {
            completion(PodCommsError.noPodPaired.localizedDescription)
            return
        }
        if self.state.podState?.isFaulted == false && self.state.podState?.unfinalizedBolus?.isFinished == false {
            self.log.info("Skipping Read Pulse Log due to bolus still in progress.")
            completion(PodCommsError.unfinalizedBolus.localizedDescription)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Read Pulse Log", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    // read the most recent 50 entries from the pulse log
                    self.emitConfirmationBeep(session: session, beepConfigType: .bipBip)
                    let podInfoResponse1 = try session.readPodInfo(podInfoResponseSubType: .pulseLogRecent)
                    guard let podInfoPulseLogRecent = podInfoResponse1.podInfo as? PodInfoPulseLogRecent else {
                        self.log.error("Unable to decode for PulseLogRecent: %s", String(describing: podInfoResponse1))
                        completion(PodCommsError.unexpectedResponse(response: .podInfoResponse).localizedDescription)
                        return
                    }
                    var lastPulseNumber = Int(podInfoPulseLogRecent.indexLastEntry)
                    var str = pulseLogString(pulseLogEntries: podInfoPulseLogRecent.pulseLog, lastPulseNumber: lastPulseNumber)

                    // read up to the previous 50 entries from the pulse log
                    self.emitConfirmationBeep(session: session, beepConfigType: .bipBip)
                    let podInfoResponse2 = try session.readPodInfo(podInfoResponseSubType: .pulseLogPrevious)
                    guard let podInfoPulseLogPrevious = podInfoResponse2.podInfo as? PodInfoPulseLogPrevious else {
                        self.log.error("Unable to decode for PulseLogPrevious: %s", String(describing: podInfoResponse1))
                        completion(PodCommsError.unexpectedResponse(response: .podInfoResponse).localizedDescription)
                        return
                    }
                    lastPulseNumber -= podInfoPulseLogRecent.pulseLog.count
                    str += pulseLogString(pulseLogEntries: podInfoPulseLogPrevious.pulseLog, lastPulseNumber: lastPulseNumber)

                    self.emitConfirmationBeep(session: session, beepConfigType: .beeeeeep)
                    completion(str)
                } catch let error {
                    completion(error.localizedDescription)
                }
            case .failure(let error):
                completion(error.localizedDescription)
            }
        }
    }

    public func setConfirmationBeeps(enabled: Bool, completion: @escaping (Error?) -> Void) {
        self.log.default("Set Confirmation Beeps to %s", String(describing: enabled))
        guard self.hasActivePod else {
            self.confirmationBeeps = enabled // set here to allow changes on a faulted Pod
            completion(nil)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        let name: String = enabled ? "Enable Confirmation Beeps" : "Disable Confirmation Beeps"
        self.podComms.runSession(withName: name, using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                let beepConfigType: BeepConfigType = enabled ? .bipBip : .noBeep
                let basalCompletionBeep = enabled
                let tempBasalCompletionBeep = enabled && tempBasalConfirmationBeeps
                let bolusCompletionBeep = enabled

                // enable/disable Pod completion beeps for any in-progress insulin delivery
                let result = session.beepConfig(beepConfigType: beepConfigType, basalCompletionBeep: basalCompletionBeep, tempBasalCompletionBeep: tempBasalCompletionBeep, bolusCompletionBeep: bolusCompletionBeep)

                switch result {
                case .success:
                    self.confirmationBeeps = enabled
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            case .failure(let error):
                completion(error)
            }
        }
    }
}

// MARK: - PumpManager
extension OmnipodPumpManager: PumpManager {

    public static let managerIdentifier: String = "Omnipod"

    public static let localizedTitle = LocalizedString("Omnipod", comment: "Generic title of the omnipod pump manager")

    public var supportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported bolus volume
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public var supportedBasalRates: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported scheduled basal rate
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        // We do support rounding a 0 U volume to 0
        return supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        // We do support rounding a 0 U/hr rate to 0
        return supportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    public var maximumBasalScheduleEntryCount: Int {
        return Pod.maximumBasalScheduleEntryCount
    }

    public var minimumBasalScheduleEntryDuration: TimeInterval {
        return Pod.minimumBasalScheduleEntryDuration
    }

    public var pumpRecordsBasalProfileStartEvents: Bool {
        return false
    }

    public var pumpReservoirCapacity: Double {
        return Pod.reservoirCapacity
    }

    public var lastReconciliation: Date? {
        return self.state.podState?.lastInsulinMeasurements?.validTime
    }

    public var status: PumpManagerStatus {
        // Acquire the lock just once
        let state = self.state

        return status(for: state)
    }

    public var rawState: PumpManager.RawStateValue {
        return state.rawValue
    }

    public var pumpManagerDelegate: PumpManagerDelegate? {
        get {
            return pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue

            // TODO: is there still a scenario where this is required?
            // self.schedulePodExpirationNotification()
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            return pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }

    // MARK: Methods

    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Suspend", using: rileyLinkSelector) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(error)
                return
            }

            defer {
                self.setState({ (state) in
                    state.suspendEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.suspendEngageState = .engaging
            })

            let beepType: BeepType = self.confirmationBeeps ? .beeeeeep : .noBeep
            let result = session.cancelDelivery(deliveryType: .all, beepType: beepType)
            switch result {
            case .certainFailure(let error):
                completion(error)
            case .uncertainFailure(let error):
                completion(error)
            case .success:
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            }
        }
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Resume", using: rileyLinkSelector) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(error)
                return
            }

            defer {
                self.setState({ (state) in
                    state.suspendEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.suspendEngageState = .disengaging
            })

            do {
                let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                let beep = self.confirmationBeeps
                let _ = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            } catch (let error) {
                completion(error)
            }
        }
    }

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        rileyLinkDeviceProvider.timerTickEnabled = self.state.isPumpDataStale || mustProvideBLEHeartbeat
    }
    
    // Called only from pumpDelegate notify block
    private func recommendLoopIfNeeded(_ delegate: PumpManagerDelegate?) {
        if lastLoopRecommendation == nil || lastLoopRecommendation!.timeIntervalSinceNow < .minutes(-4.5) {
            self.log.default("Recommending Loop")
            lastLoopRecommendation = Date()
            delegate?.pumpManagerRecommendsLoop(self)
        }
    }

    public func assertCurrentPumpData() {
        let shouldFetchStatus = setStateWithResult { (state) -> Bool? in
            guard state.hasActivePod else {
                return nil // No active pod
            }

            return state.isPumpDataStale
        }

        switch shouldFetchStatus {
        case .none:
            return // No active pod
        case true?:
            log.default("Fetching status because pumpData is too old")
            getPodStatus(storeDosesOnSuccess: true) { (response) in
                self.pumpDelegate.notify({ (delegate) in
                    switch response {
                    case .success:
                        self.recommendLoopIfNeeded(delegate)
                    case .failure(let error):
                        self.log.default("Not recommending Loop because pump data is stale: %@", String(describing: error))
                        if let error = error as? PumpManagerError {
                            delegate?.pumpManager(self, didError: error)
                        }
                    }
                })
            }
        case false?:
            log.default("Skipping status update because pumpData is fresh")
            pumpDelegate.notify { (delegate) in
                self.recommendLoopIfNeeded(delegate)
            }
        }
    }

    public func enactBolus(units: Double, at startDate: Date, willRequest: @escaping (DoseEntry) -> Void, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {
        guard self.hasActivePod else {
            completion(.failure(SetBolusError.certain(OmnipodPumpManagerError.noPodPaired)))
            return
        }

        // Round to nearest supported volume
        let enactUnits = roundToSupportedBolusVolume(units: units)

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Bolus", using: rileyLinkSelector) { (result) in
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.failure(SetBolusError.certain(error)))
                return
            }
            
            defer {
                self.setState({ (state) in
                    state.bolusEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.bolusEngageState = .engaging
            })

            var podStatus: StatusResponse

            do {
                podStatus = try session.getStatus()
            } catch let error {
                completion(.failure(SetBolusError.certain(error as? PodCommsError ?? PodCommsError.commsError(error: error))))
                return
            }

            // If pod suspended, resume basal before bolusing
            if podStatus.deliveryStatus == .suspended {
                do {
                    let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                    let beep = self.confirmationBeeps
                    podStatus = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)
                } catch let error {
                    completion(.failure(SetBolusError.certain(error as? PodCommsError ?? PodCommsError.commsError(error: error))))
                    return
                }
            }

            guard !podStatus.deliveryStatus.bolusing else {
                completion(.failure(SetBolusError.certain(PodCommsError.unfinalizedBolus)))
                return
            }

            let date = Date()
            let endDate = date.addingTimeInterval(enactUnits / Pod.bolusDeliveryRate)
            let dose = DoseEntry(type: .bolus, startDate: date, endDate: endDate, value: enactUnits, unit: .units)
            willRequest(dose)

            let beep = self.confirmationBeeps
            let result = session.bolus(units: enactUnits, acknowledgementBeep: beep, completionBeep: beep)
            session.dosesForStorage() { (doses) -> Bool in
                return self.store(doses: doses, in: session)
            }

            switch result {
            case .success:
                completion(.success(dose))
            case .certainFailure(let error):
                completion(.failure(SetBolusError.certain(error)))
            case .uncertainFailure(let error):
                completion(.failure(SetBolusError.uncertain(error)))
            }
        }
    }

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        guard self.hasActivePod else {
            completion(.failure(OmnipodPumpManagerError.noPodPaired))
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Cancel Bolus", using: rileyLinkSelector) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.failure(error))
                return
            }

            do {
                defer {
                    self.setState({ (state) in
                        state.bolusEngageState = .stable
                    })
                }
                self.setState({ (state) in
                    state.bolusEngageState = .disengaging
                })
                
                if let bolus = self.state.podState?.unfinalizedBolus, !bolus.isFinished, bolus.scheduledCertainty == .uncertain {
                    let status = try session.getStatus()
                    
                    if !status.deliveryStatus.bolusing {
                        completion(.success(nil))
                        return
                    }
                }

                // when cancelling a bolus give a type 6 beeeeeep to match PDM if doing bolus confirmation beeps
                let beeptype: BeepType = self.confirmationBeeps ? .beeeeeep : .noBeep
                let result = session.cancelDelivery(deliveryType: .bolus, beepType: beeptype)
                switch result {
                case .certainFailure(let error):
                    throw error
                case .uncertainFailure(let error):
                    throw error
                case .success(_, let canceledBolus):
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }

                    let canceledDoseEntry: DoseEntry? = canceledBolus != nil ? DoseEntry(canceledBolus!) : nil
                    completion(.success(canceledDoseEntry))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {
        guard self.hasActivePod else {
            completion(.failure(OmnipodPumpManagerError.noPodPaired))
            return
        }

        // Round to nearest supported rate
        let rate = roundToSupportedBasalRate(unitsPerHour: unitsPerHour)

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Enact Temp Basal", using: rileyLinkSelector) { (result) in
            self.log.info("Enact temp basal %.03fU/hr for %ds", rate, Int(duration))
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.failure(error))
                return
            }

            do {
                let preError = self.setStateWithResult({ (state) -> PodCommsError? in
                    if case .some(.suspended) = state.podState?.suspendState {
                        self.log.info("Not enacting temp basal because podState indicates pod is suspended.")
                        return .podSuspended
                    }

                    guard state.podState?.unfinalizedBolus?.isFinished != false else {
                        self.log.info("Not enacting temp basal because podState indicates unfinalized bolus in progress.")
                        return .unfinalizedBolus
                    }

                    return nil
                })

                if let error = preError {
                    throw error
                }

                let status: StatusResponse
                let canceledDose: UnfinalizedDose?

                // if resuming a normal basal as denoted by a 0 duration temp basal, use a confirmation beep if appropriate
                let beep: BeepType = duration < .ulpOfOne && self.confirmationBeeps && tempBasalConfirmationBeeps ? .beep : .noBeep
                let result = session.cancelDelivery(deliveryType: .tempBasal, beepType: beep)
                switch result {
                case .certainFailure(let error):
                    throw error
                case .uncertainFailure(let error):
                    throw error
                case .success(let cancelTempStatus, let dose):
                    status = cancelTempStatus
                    canceledDose = dose
                }

                guard !status.deliveryStatus.bolusing else {
                    throw PodCommsError.unfinalizedBolus
                }

                guard status.deliveryStatus != .suspended else {
                    self.log.info("Canceling temp basal because status return indicates pod is suspended.")
                    throw PodCommsError.podSuspended
                }

                defer {
                    self.setState({ (state) in
                        state.tempBasalEngageState = .stable
                    })
                }

                if duration < .ulpOfOne {
                    // 0 duration temp basals are used to cancel any existing temp basal
                    self.setState({ (state) in
                        state.tempBasalEngageState = .disengaging
                    })
                    let cancelTime = canceledDose?.finishTime ?? Date()
                    let dose = DoseEntry(type: .tempBasal, startDate: cancelTime, endDate: cancelTime, value: 0, unit: .unitsPerHour)
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }
                    completion(.success(dose))
                } else {
                    self.setState({ (state) in
                        state.tempBasalEngageState = .engaging
                    })

                    let beep = self.confirmationBeeps && tempBasalConfirmationBeeps
                    let result = session.setTempBasal(rate: rate, duration: duration, acknowledgementBeep: beep, completionBeep: beep)
                    let basalStart = Date()
                    let dose = DoseEntry(type: .tempBasal, startDate: basalStart, endDate: basalStart.addingTimeInterval(duration), value: rate, unit: .unitsPerHour)
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }
                    switch result {
                    case .success:
                        completion(.success(dose))
                    case .uncertainFailure(let error):
                        self.log.error("Temp basal uncertain error: %@", String(describing: error))
                        completion(.success(dose))
                    case .certainFailure(let error):
                        completion(.failure(error))
                    }
                }
            } catch let error {
                self.log.error("Error during temp basal: %@", String(describing: error))
                completion(.failure(error))
            }
        }
    }

    /// Returns a dose estimator for the current bolus, if one is in progress
    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        if case .inProgress(let dose) = bolusState(for: self.state) {
            return PodDoseProgressEstimator(dose: dose, pumpManager: self, reportingQueue: dispatchQueue)
        }
        return nil
    }

    // This cannot be called from within the lockedState lock!
    func store(doses: [UnfinalizedDose], in session: PodCommsSession) -> Bool {
        session.assertOnSessionQueue()

        // We block the session until the data's confirmed stored by the delegate
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        store(doses: doses) { (error) in
            success = (error == nil)
            semaphore.signal()
        }

        semaphore.wait()

        if success {
            setState { (state) in
                state.lastPumpDataReportDate = Date()
            }
        }
        return success
    }

    func store(doses: [UnfinalizedDose], completion: @escaping (_ error: Error?) -> Void) {
        let lastPumpReconciliation = lastReconciliation

        pumpDelegate.notify { (delegate) in
            guard let delegate = delegate else {
                preconditionFailure("pumpManagerDelegate cannot be nil")
            }

            delegate.pumpManager(self, hasNewPumpEvents: doses.map { NewPumpEvent($0) }, lastReconciliation: lastPumpReconciliation, completion: { (error) in
                if let error = error {
                    self.log.error("Error storing pod events: %@", String(describing: error))
                } else {
                    self.log.info("DU: Stored pod events: %@", String(describing: doses))
                }

                completion(error)
            })
        }
    }
}

extension OmnipodPumpManager: MessageLogger {
    func didSend(_ message: Data) {
        log.default("didSend: %{public}@", message.hexadecimalString)
        self.logDeviceCommunication(message.hexadecimalString, type: .send)
    }
    
    func didReceive(_ message: Data) {
        log.default("didReceive: %{public}@", message.hexadecimalString)
        self.logDeviceCommunication(message.hexadecimalString, type: .receive)
    }
}

extension OmnipodPumpManager: PodCommsDelegate {
    func podComms(_ podComms: PodComms, didChange podState: PodState) {
        setState { (state) in
            // Check for any updates to bolus certainty, and log them
            if let bolus = state.podState?.unfinalizedBolus, bolus.scheduledCertainty == .uncertain, !bolus.isFinished {
                if podState.unfinalizedBolus?.scheduledCertainty == .some(.certain) {
                    self.log.default("Resolved bolus uncertainty: did bolus")
                } else if podState.unfinalizedBolus == nil {
                    self.log.default("Resolved bolus uncertainty: did not bolus")
                }
            }
            state.podState = podState
        }
    }
}

