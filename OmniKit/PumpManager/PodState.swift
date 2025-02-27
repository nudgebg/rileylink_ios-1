//
//  PodState.swift
//  OmniKit
//
//  Created by Pete Schwamb on 10/13/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import Foundation

public enum SetupProgress: Int {
    case addressAssigned = 0
    case podConfigured
    case startingPrime
    case priming
    case settingInitialBasalSchedule
    case initialBasalScheduleSet
    case startingInsertCannula
    case cannulaInserting
    case completed
    case activationTimeout
    
    public var primingNeeded: Bool {
        return self.rawValue < SetupProgress.priming.rawValue
    }
    
    public var needsInitialBasalSchedule: Bool {
        return self.rawValue < SetupProgress.initialBasalScheduleSet.rawValue
    }

    public var needsCannulaInsertion: Bool {
        return self.rawValue < SetupProgress.completed.rawValue
    }
}

// TODO: Mutating functions aren't guaranteed to synchronize read/write calls.
// mutating funcs should be moved to something like this:
// extension Locked where T == PodState {
// }
public struct PodState: RawRepresentable, Equatable, CustomDebugStringConvertible {
    
    public typealias RawValue = [String: Any]
    
    public let address: UInt32
    fileprivate var nonceState: NonceState

    public var activatedAt: Date?
    public var expiresAt: Date?  // set based on StatusResponse timeActive and can change with Pod clock drift and/or system time change

    public var setupUnitsDelivered: Double?

    public let piVersion: String
    public let pmVersion: String
    public let lot: UInt32
    public let tid: UInt32
    var activeAlertSlots: AlertSet
    public var lastInsulinMeasurements: PodInsulinMeasurements?

    public var unfinalizedBolus: UnfinalizedDose?
    public var unfinalizedTempBasal: UnfinalizedDose?
    public var unfinalizedSuspend: UnfinalizedDose?
    public var unfinalizedResume: UnfinalizedDose?

    var finalizedDoses: [UnfinalizedDose]

    public var dosesToStore: [UnfinalizedDose] {
        return  finalizedDoses + [unfinalizedTempBasal, unfinalizedSuspend, unfinalizedBolus].compactMap {$0}
    }

    public var suspendState: SuspendState

    public var isSuspended: Bool {
        if case .suspended = suspendState {
            return true
        }
        return false
    }

    public var fault: DetailedStatus?
    public var messageTransportState: MessageTransportState
    public var primeFinishTime: Date?
    public var setupProgress: SetupProgress
    public var configuredAlerts: [AlertSlot: PodAlert]

    public var activeAlerts: [AlertSlot: PodAlert] {
        var active = [AlertSlot: PodAlert]()
        for slot in activeAlertSlots {
            if let alert = configuredAlerts[slot] {
                active[slot] = alert
            }
        }
        return active
    }
    
    public init(address: UInt32, piVersion: String, pmVersion: String, lot: UInt32, tid: UInt32, packetNumber: Int = 0, messageNumber: Int = 0) {
        self.address = address
        self.nonceState = NonceState(lot: lot, tid: tid)
        self.piVersion = piVersion
        self.pmVersion = pmVersion
        self.lot = lot
        self.tid = tid
        self.lastInsulinMeasurements = nil
        self.finalizedDoses = []
        self.suspendState = .resumed(Date())
        self.fault = nil
        self.activeAlertSlots = .none
        self.messageTransportState = MessageTransportState(packetNumber: packetNumber, messageNumber: messageNumber)
        self.primeFinishTime = nil
        self.setupProgress = .addressAssigned
        self.configuredAlerts = [.slot7: .waitingForPairingReminder]
    }
    
    public var unfinishedPairing: Bool {
        return setupProgress != .completed
    }
    
    public var readyForCannulaInsertion: Bool {
        guard let primeFinishTime = self.primeFinishTime else {
            return false
        }
        return !setupProgress.primingNeeded && primeFinishTime.timeIntervalSinceNow < 0
    }

    public var isActive: Bool {
        return setupProgress == .completed && fault == nil
    }

    // variation on isActive that doesn't care if Pod is faulted
    public var isSetupComplete: Bool {
        return setupProgress == .completed
    }

    public var isFaulted: Bool {
        return fault != nil || setupProgress == .activationTimeout
    }

    public mutating func advanceToNextNonce() {
        nonceState.advanceToNextNonce()
    }
    
    public var currentNonce: UInt32 {
        return nonceState.currentNonce
    }
    
    public mutating func resyncNonce(syncWord: UInt16, sentNonce: UInt32, messageSequenceNum: Int) {
        let sum = (sentNonce & 0xffff) + UInt32(crc16Table[messageSequenceNum]) + (lot & 0xffff) + (tid & 0xffff)
        let seed = UInt16(sum & 0xffff) ^ syncWord
        nonceState = NonceState(lot: lot, tid: tid, seed: seed)
    }
    
    private mutating func updatePodTimes(timeActive: TimeInterval) -> Date {
        let now = Date()
        let activatedAtComputed = now - timeActive
        if activatedAt == nil {
            self.activatedAt = activatedAtComputed
        }
        let expiresAtComputed = activatedAtComputed + Pod.nominalPodLife
        if expiresAt == nil {
            self.expiresAt = expiresAtComputed
        } else if expiresAtComputed < self.expiresAt! || expiresAtComputed > (self.expiresAt! + TimeInterval(minutes: 1)) {
            // The computed expiresAt time is earlier than or more than a minute later than the current expiresAt time,
            // so use the computed expiresAt time instead to handle Pod clock drift and/or system time changes issues.
            // The more than a minute later test prevents oscillation of expiresAt based on the timing of the responses.
            self.expiresAt = expiresAtComputed
        }
        return now
    }

    public mutating func updateFromStatusResponse(_ response: StatusResponse) {
        let now = updatePodTimes(timeActive: response.timeActive)
        updateDeliveryStatus(deliveryStatus: response.deliveryStatus)
        lastInsulinMeasurements = PodInsulinMeasurements(insulinDelivered: response.insulin, reservoirLevel: response.reservoirLevel, setupUnitsDelivered: setupUnitsDelivered, validTime: now)
        activeAlertSlots = response.alerts
    }

    public mutating func updateFromDetailedStatusResponse(_ response: DetailedStatus) {
        let now = updatePodTimes(timeActive: response.timeActive)
        updateDeliveryStatus(deliveryStatus: response.deliveryStatus)
        lastInsulinMeasurements = PodInsulinMeasurements(insulinDelivered: response.totalInsulinDelivered, reservoirLevel: response.reservoirLevel, setupUnitsDelivered: setupUnitsDelivered, validTime: now)
        activeAlertSlots = response.unacknowledgedAlerts
    }

    public mutating func registerConfiguredAlert(slot: AlertSlot, alert: PodAlert) {
        configuredAlerts[slot] = alert
    }

    public mutating func finalizeFinishedDoses() {
        if let bolus = unfinalizedBolus, bolus.isFinished {
            finalizedDoses.append(bolus)
            unfinalizedBolus = nil
        }

        if let tempBasal = unfinalizedTempBasal, tempBasal.isFinished {
            finalizedDoses.append(tempBasal)
            unfinalizedTempBasal = nil
        }
    }
    
    private mutating func updateDeliveryStatus(deliveryStatus: DeliveryStatus) {
        finalizeFinishedDoses()

        if let bolus = unfinalizedBolus, bolus.scheduledCertainty == .uncertain {
            if deliveryStatus.bolusing {
                // Bolus did schedule
                unfinalizedBolus?.scheduledCertainty = .certain
            } else {
                // Bolus didn't happen
                unfinalizedBolus = nil
            }
        }

        if let tempBasal = unfinalizedTempBasal, tempBasal.scheduledCertainty == .uncertain {
            if deliveryStatus.tempBasalRunning {
                // Temp basal did schedule
                unfinalizedTempBasal?.scheduledCertainty = .certain
            } else {
                // Temp basal didn't happen
                unfinalizedTempBasal = nil
            }
        }

        if let resume = unfinalizedResume, resume.scheduledCertainty == .uncertain {
            if deliveryStatus != .suspended {
                // Resume was enacted
                unfinalizedResume?.scheduledCertainty = .certain
            } else {
                // Resume wasn't enacted
                unfinalizedResume = nil
            }
        }

        if let suspend = unfinalizedSuspend {
            if suspend.scheduledCertainty == .uncertain {
                if deliveryStatus == .suspended {
                    // Suspend was enacted
                    unfinalizedSuspend?.scheduledCertainty = .certain
                } else {
                    // Suspend wasn't enacted
                    unfinalizedSuspend = nil
                }
            }

            if let resume = unfinalizedResume, suspend.startTime < resume.startTime {
                finalizedDoses.append(suspend)
                finalizedDoses.append(resume)
                unfinalizedSuspend = nil
                unfinalizedResume = nil
            }
        }
    }

    // MARK: - RawRepresentable
    public init?(rawValue: RawValue) {

        guard
            let address = rawValue["address"] as? UInt32,
            let nonceStateRaw = rawValue["nonceState"] as? NonceState.RawValue,
            let nonceState = NonceState(rawValue: nonceStateRaw),
            let piVersion = rawValue["piVersion"] as? String,
            let pmVersion = rawValue["pmVersion"] as? String,
            let lot = rawValue["lot"] as? UInt32,
            let tid = rawValue["tid"] as? UInt32
            else {
                return nil
            }
        
        self.address = address
        self.nonceState = nonceState
        self.piVersion = piVersion
        self.pmVersion = pmVersion
        self.lot = lot
        self.tid = tid


        if let activatedAt = rawValue["activatedAt"] as? Date {
            self.activatedAt = activatedAt
            if let expiresAt = rawValue["expiresAt"] as? Date {
                self.expiresAt = expiresAt
            } else {
                self.expiresAt = activatedAt + Pod.nominalPodLife
            }
        }

        if let setupUnitsDelivered = rawValue["setupUnitsDelivered"] as? Double {
            self.setupUnitsDelivered = setupUnitsDelivered
        }

        if let suspended = rawValue["suspended"] as? Bool {
            // Migrate old value
            if suspended {
                suspendState = .suspended(Date())
            } else {
                suspendState = .resumed(Date())
            }
        } else if let rawSuspendState = rawValue["suspendState"] as? SuspendState.RawValue, let suspendState = SuspendState(rawValue: rawSuspendState) {
            self.suspendState = suspendState
        } else {
            return nil
        }

        if let rawUnfinalizedBolus = rawValue["unfinalizedBolus"] as? UnfinalizedDose.RawValue
        {
            self.unfinalizedBolus = UnfinalizedDose(rawValue: rawUnfinalizedBolus)
        }

        if let rawUnfinalizedTempBasal = rawValue["unfinalizedTempBasal"] as? UnfinalizedDose.RawValue
        {
            self.unfinalizedTempBasal = UnfinalizedDose(rawValue: rawUnfinalizedTempBasal)
        }

        if let rawUnfinalizedSuspend = rawValue["unfinalizedSuspend"] as? UnfinalizedDose.RawValue
        {
            self.unfinalizedSuspend = UnfinalizedDose(rawValue: rawUnfinalizedSuspend)
        }

        if let rawUnfinalizedResume = rawValue["unfinalizedResume"] as? UnfinalizedDose.RawValue
        {
            self.unfinalizedResume = UnfinalizedDose(rawValue: rawUnfinalizedResume)
        }

        if let rawLastInsulinMeasurements = rawValue["lastInsulinMeasurements"] as? PodInsulinMeasurements.RawValue {
            self.lastInsulinMeasurements = PodInsulinMeasurements(rawValue: rawLastInsulinMeasurements)
        } else {
            self.lastInsulinMeasurements = nil
        }
        
        if let rawFinalizedDoses = rawValue["finalizedDoses"] as? [UnfinalizedDose.RawValue] {
            self.finalizedDoses = rawFinalizedDoses.compactMap( { UnfinalizedDose(rawValue: $0) } )
        } else {
            self.finalizedDoses = []
        }
        
        if let rawFault = rawValue["fault"] as? DetailedStatus.RawValue,
           let fault = DetailedStatus(rawValue: rawFault),
           fault.faultEventCode.faultType != .noFaults
        {
            self.fault = fault
        } else {
            self.fault = nil
        }
        
        if let alarmsRawValue = rawValue["alerts"] as? UInt8 {
            self.activeAlertSlots = AlertSet(rawValue: alarmsRawValue)
        } else {
            self.activeAlertSlots = .none
        }
        
        if let setupProgressRaw = rawValue["setupProgress"] as? Int,
            let setupProgress = SetupProgress(rawValue: setupProgressRaw)
        {
            self.setupProgress = setupProgress
        } else {
            // Migrate
            self.setupProgress = .completed
        }
        
        if let messageTransportStateRaw = rawValue["messageTransportState"] as? MessageTransportState.RawValue,
            let messageTransportState = MessageTransportState(rawValue: messageTransportStateRaw)
        {
            self.messageTransportState = messageTransportState
        } else {
            self.messageTransportState = MessageTransportState(packetNumber: 0, messageNumber: 0)
        }

        if let rawConfiguredAlerts = rawValue["configuredAlerts"] as? [String: PodAlert.RawValue] {
            var configuredAlerts = [AlertSlot: PodAlert]()
            for (rawSlot, rawAlert) in rawConfiguredAlerts {
                if let slotNum = UInt8(rawSlot), let slot = AlertSlot(rawValue: slotNum), let alert = PodAlert(rawValue: rawAlert) {
                    configuredAlerts[slot] = alert
                }
            }
            self.configuredAlerts = configuredAlerts
        } else {
            // Assume migration, and set up with alerts that are normally configured
            self.configuredAlerts = [
                .slot2: .shutdownImminentAlarm(0),
                .slot3: .expirationAlert(0),
                .slot4: .lowReservoirAlarm(0),
                .slot7: .expirationAdvisoryAlarm(alarmTime: 0, duration: 0)
            ]
        }
        
        self.primeFinishTime = rawValue["primeFinishTime"] as? Date
    }
    
    public var rawValue: RawValue {
        var rawValue: RawValue = [
            "address": address,
            "nonceState": nonceState.rawValue,
            "piVersion": piVersion,
            "pmVersion": pmVersion,
            "lot": lot,
            "tid": tid,
            "suspendState": suspendState.rawValue,
            "finalizedDoses": finalizedDoses.map( { $0.rawValue }),
            "alerts": activeAlertSlots.rawValue,
            "messageTransportState": messageTransportState.rawValue,
            "setupProgress": setupProgress.rawValue
            ]
        
        if let unfinalizedBolus = self.unfinalizedBolus {
            rawValue["unfinalizedBolus"] = unfinalizedBolus.rawValue
        }
        
        if let unfinalizedTempBasal = self.unfinalizedTempBasal {
            rawValue["unfinalizedTempBasal"] = unfinalizedTempBasal.rawValue
        }

        if let unfinalizedSuspend = self.unfinalizedSuspend {
            rawValue["unfinalizedSuspend"] = unfinalizedSuspend.rawValue
        }

        if let unfinalizedResume = self.unfinalizedResume {
            rawValue["unfinalizedResume"] = unfinalizedResume.rawValue
        }

        if let lastInsulinMeasurements = self.lastInsulinMeasurements {
            rawValue["lastInsulinMeasurements"] = lastInsulinMeasurements.rawValue
        }
        
        if let fault = self.fault {
            rawValue["fault"] = fault.rawValue
        }

        if let primeFinishTime = primeFinishTime {
            rawValue["primeFinishTime"] = primeFinishTime
        }

        if let activatedAt = activatedAt {
            rawValue["activatedAt"] = activatedAt
        }

        if let expiresAt = expiresAt {
            rawValue["expiresAt"] = expiresAt
        }

        if let setupUnitsDelivered = setupUnitsDelivered {
            rawValue["setupUnitsDelivered"] = setupUnitsDelivered
        }

        if configuredAlerts.count > 0 {
            let rawConfiguredAlerts = Dictionary(uniqueKeysWithValues:
                configuredAlerts.map { slot, alarm in (String(describing: slot.rawValue), alarm.rawValue) })
            rawValue["configuredAlerts"] = rawConfiguredAlerts
        }

        return rawValue
    }
    
    // MARK: - CustomDebugStringConvertible
    
    public var debugDescription: String {
        return [
            "### PodState",
            "* address: \(String(format: "%04X", address))",
            "* activatedAt: \(String(reflecting: activatedAt))",
            "* expiresAt: \(String(reflecting: expiresAt))",
            "* setupUnitsDelivered: \(String(reflecting: setupUnitsDelivered))",
            "* piVersion: \(piVersion)",
            "* pmVersion: \(pmVersion)",
            "* lot: \(lot)",
            "* tid: \(tid)",
            "* suspendState: \(suspendState)",
            "* unfinalizedBolus: \(String(describing: unfinalizedBolus))",
            "* unfinalizedTempBasal: \(String(describing: unfinalizedTempBasal))",
            "* unfinalizedSuspend: \(String(describing: unfinalizedSuspend))",
            "* unfinalizedResume: \(String(describing: unfinalizedResume))",
            "* finalizedDoses: \(String(describing: finalizedDoses))",
            "* activeAlerts: \(String(describing: activeAlerts))",
            "* messageTransportState: \(String(describing: messageTransportState))",
            "* setupProgress: \(setupProgress)",
            "* primeFinishTime: \(String(describing: primeFinishTime))",
            "* configuredAlerts: \(String(describing: configuredAlerts))",
            "",
            fault != nil ? String(reflecting: fault!) : "fault: nil",
            "",
        ].joined(separator: "\n")
    }
}

fileprivate struct NonceState: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]
    
    var table: [UInt32]
    var idx: UInt8
    
    public init(lot: UInt32 = 0, tid: UInt32 = 0, seed: UInt16 = 0) {
        table = Array(repeating: UInt32(0), count: 2 + 16)
        table[0] = (lot & 0xFFFF) &+ (lot >> 16) &+ 0x55543DC3
        table[1] = (tid & 0xFFFF) &+ (tid >> 16) &+ 0xAAAAE44E
        
        idx = 0
        
        table[0] += UInt32((seed & 0x00ff))
        table[1] += UInt32((seed & 0xff00) >> 8)
        
        for i in 0..<16 {
            table[2 + i] = generateEntry()
        }
        
        idx = UInt8((table[0] + table[1]) & 0x0F)
    }

    private mutating func generateEntry() -> UInt32 {
        table[0] = (table[0] >> 16) &+ ((table[0] & 0xFFFF) &* 0x5D7F)
        table[1] = (table[1] >> 16) &+ ((table[1] & 0xFFFF) &* 0x8CA0)
        return table[1] &+ ((table[0] & 0xFFFF) << 16)
    }
    
    public mutating func advanceToNextNonce() {
        let nonce = currentNonce
        table[Int(2 + idx)] = generateEntry()
        idx = UInt8(nonce & 0x0F)
    }
    
    public var currentNonce: UInt32 {
        return table[Int(2 + idx)]
    }
    
    // RawRepresentable
    public init?(rawValue: RawValue) {
        guard
            let table = rawValue["table"] as? [UInt32],
            let idx = rawValue["idx"] as? UInt8
            else {
                return nil
        }
        self.table = table
        self.idx = idx
    }
    
    public var rawValue: RawValue {
        let rawValue: RawValue = [
            "table": table,
            "idx": idx,
        ]
        
        return rawValue
    }
}


public enum SuspendState: Equatable, RawRepresentable {
    public typealias RawValue = [String: Any]

    private enum SuspendStateType: Int {
        case suspend, resume
    }

    case suspended(Date)
    case resumed(Date)

    private var identifier: Int {
        switch self {
        case .suspended:
            return 1
        case .resumed:
            return 2
        }
    }

    public init?(rawValue: RawValue) {
        guard let suspendStateType = rawValue["case"] as? SuspendStateType.RawValue,
            let date = rawValue["date"] as? Date else {
                return nil
        }
        switch SuspendStateType(rawValue: suspendStateType) {
        case .suspend?:
            self = .suspended(date)
        case .resume?:
            self = .resumed(date)
        default:
            return nil
        }
    }

    public var rawValue: RawValue {
        switch self {
        case .suspended(let date):
            return [
                "case": SuspendStateType.suspend.rawValue,
                "date": date
            ]
        case .resumed(let date):
            return [
                "case": SuspendStateType.resume.rawValue,
                "date": date
            ]
        }
    }
}
