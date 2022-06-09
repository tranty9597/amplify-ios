//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Amplify
import Foundation

protocol SessionClientBehaviour {
    var currentSession: PinpointSession { get }

    func startPinpointSession()
    func validateOrRetrieveSession(_ session: PinpointSession?) -> PinpointSession
}

struct SessionClientConfiguration {
    let appId: String
    let uniqueDeviceId: String
    let sessionTimeout: TimeInterval
}

class SessionClient: SessionClientBehaviour {
    private var session: PinpointSession
    
    private let activityTracker: ActivityTrackerBehaviour
    private let analyticsClient: AnalyticsClientBehaviour
    private let archiver: AmplifyArchiverBehaviour
    private let configuration: SessionClientConfiguration
    private let endpointClient: EndpointClient
    private let sessionClientQueue = DispatchQueue(label: Constants.queue,
                                                   attributes: .concurrent)
    private let userDefaults: UserDefaultsBehaviour

    convenience init(context: PinpointContext,
                     archiver: AmplifyArchiverBehaviour = AmplifyArchiver(),
                     activityTracker: ActivityTrackerBehaviour? = nil) {
        self.init(activityTracker: activityTracker ?? ActivityTracker.create(from: context),
                  analyticsClient: context.analyticsClient,
                  archiver: archiver,
                  configuration: SessionClientConfiguration(appId: context.configuration.appId,
                                                            uniqueDeviceId: context.uniqueId,
                                                            sessionTimeout: context.configuration.sessionTimeout),
                  endpointClient: context.targetingClient,
                  userDefaults: context.userDefaults)
    }

    init(activityTracker: ActivityTrackerBehaviour,
         analyticsClient: AnalyticsClientBehaviour,
         archiver: AmplifyArchiverBehaviour = AmplifyArchiver(),
         configuration: SessionClientConfiguration,
         endpointClient: EndpointClient,
         userDefaults: UserDefaultsBehaviour) {
        self.activityTracker = activityTracker
        self.analyticsClient = analyticsClient
        self.archiver = archiver
        self.configuration = configuration
        self.endpointClient = endpointClient
        self.userDefaults = userDefaults
        session = Self.retrieveStoredSession(from: userDefaults, using: archiver) ?? PinpointSession.invalid
    }

    var currentSession: PinpointSession {
        if session == PinpointSession.invalid {
            startNewSession()
        }
        return session
    }

    func startPinpointSession() {
        activityTracker.beginActivityTracking { [weak self] newState in
            guard let self = self else { return }
            self.log.verbose("New state received: \(newState)")
            self.sessionClientQueue.sync(flags: .barrier) {
                self.respond(to: newState)
            }
        }

        sessionClientQueue.sync(flags: .barrier) {
            if session != PinpointSession.invalid {
                endSession()
            }
            startNewSession()
        }
    }

    func validateOrRetrieveSession(_ session: PinpointSession?) -> PinpointSession {
        if let session = session, !session.sessionId.isEmpty {
            return session
        }
        
        if let storedSession = Self.retrieveStoredSession(from: userDefaults, using: archiver) {
            return storedSession
        }
        
        return PinpointSession(sessionId: PinpointSession.Constants.defaultSessionId,
                               startTime: Date(),
                               stopTime: Date())
    }

    private static func retrieveStoredSession(from userDefaults: UserDefaultsBehaviour,
                                              using archiver: AmplifyArchiverBehaviour) -> PinpointSession? {
        guard let sessionData = userDefaults.data(forKey: Constants.sessionKey),
              let storedSession = try? archiver.decode(PinpointSession.self, from: sessionData),
              !storedSession.sessionId.isEmpty else {
            return nil
        }
        
        return storedSession
    }

    private func startNewSession() {
        session = PinpointSession(appId: configuration.appId,
                                  uniqueId: configuration.uniqueDeviceId)
        saveSession()
        log.info("Session Started.")
        let startEvent = analyticsClient.createEvent(withEventType: Constants.Events.start)
        
        // Update Endpoint and record Session Start event
        Task {
            try? await endpointClient.updateEndpointProfile()
            log.verbose("Firing Session Event: Start")
            try? await analyticsClient.record(startEvent)
        }
    }

    private func saveSession() {
        do {
            let sessionData = try archiver.encode(session)
            userDefaults.save(sessionData, forKey: Constants.sessionKey)
        } catch {
            log.error("Error archiving sessionData: \(error.localizedDescription)")
        }
    }
    
    private func pauseSession() {
        session.pause()
        saveSession()
        log.info("Session Paused.")

        let pauseEvent = analyticsClient.createEvent(withEventType: Constants.Events.pause)
        Task {
            log.verbose("Firing Session Event: Pause")
            try? await analyticsClient.record(pauseEvent)
        }
    }
    
    private func resumeSession() {
        guard session.isPaused else {
            log.verbose("Session Resume Failed: Session is already runnning.")
            return
        }
        
        guard !isSessionExpired(session) else {
            log.verbose("Session has expired. Starting a fresh one...")
            endSession()
            startNewSession()
            return
        }
        
        session.resume()
        saveSession()
        log.info("Session Resumed.")

        let resumeEvent = analyticsClient.createEvent(withEventType: Constants.Events.resume)
        Task {
            log.verbose("Firing Session Event: Resume")
            try? await analyticsClient.record(resumeEvent)
        }
    }
    
    private func endSession() {
        session.stop()
        log.info("Session Stopped.")

        // TODO: Remove Global Event Source Attributes

        let stopEvent = analyticsClient.createEvent(withEventType: Constants.Events.stop)
        Task {
            log.verbose("Firing Session Event: Stop")
            try? await analyticsClient.record(stopEvent)
        }
    }
    
    private func isSessionExpired(_ session: PinpointSession) -> Bool {
        guard let stopTime = session.stopTime?.timeIntervalSince1970 else {
            return false
        }
        
        let now = Date().timeIntervalSince1970
        return now - stopTime > configuration.sessionTimeout
    }
    
    private func respond(to newState: ApplicationState) {
        switch newState {
        case .runningInBackground(let isStale):
            if isStale {
                endSession()
                Task {
                    try? await analyticsClient.submitEvents()
                }
            } else {
                pauseSession()
            }
        case .runningInForeground:
            resumeSession()
        case .terminated:
            endSession()
        case .initializing:
            break
        }
    }
}

// MARK: - DefaultLogger
extension SessionClient: DefaultLogger {}

extension SessionClient {
    struct Constants {
        static let sessionKey = "com.amazonaws.AWSPinpointSessionKey"
        static let queue = "com.amazonaws.Amplify.SessionClientQueue"
        
        struct Events {
            static let start = "_session.start"
            static let stop = "_session.stop"
            static let pause = "_session.pause"
            static let resume = "_session.resume"
        }
    }
}

private extension PinpointSession {
    static var invalid = PinpointSession(sessionId: "InvalidId", startTime: Date(), stopTime: nil)
}
