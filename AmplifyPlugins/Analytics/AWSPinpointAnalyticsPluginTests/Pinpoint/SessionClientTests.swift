//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

@testable import Amplify
import AWSPluginsCore
@testable import AmplifyTestCommon
import AWSClientRuntime
@testable import AWSPinpointAnalyticsPlugin
import XCTest

class SessionClientTests: XCTestCase {
    private var client: SessionClient!

    private var activityTracker: MockActivityTracker!
    private var analyticsClient: MockAnalyticsClient!
    private var archiver: MockArchiver!
    private var endpointClient: MockEndpointClient!
    private var userDefaults: MockUserDefaults!
    private var sessionTimeout: TimeInterval = 5
    
    override func setUp() {
        activityTracker = MockActivityTracker()
        archiver = MockArchiver()
        userDefaults = MockUserDefaults()
        analyticsClient = MockAnalyticsClient()
        endpointClient = MockEndpointClient()

        createNewSessionClient()
    }
    
    func createNewSessionClient() {
        client = SessionClient(activityTracker: activityTracker,
                               analyticsClient: analyticsClient,
                               archiver: archiver,
                               configuration: SessionClientConfiguration(appId: "appId",
                                                                         uniqueDeviceId: "deviceId",
                                                                         sessionTimeout: sessionTimeout),
                               endpointClient: endpointClient,
                               userDefaults: userDefaults)
    }
    
    func resetCounters() async {
        await analyticsClient.resetCounters()
        activityTracker.resetCounters()
        archiver.resetCounters()
        endpointClient.resetCounters()
        userDefaults.resetCounters()
    }
    
    
    func storeSession(isPaused: Bool = false, isExpired: Bool = false) {
        let start = isExpired ? Date().addingTimeInterval(-(sessionTimeout + 1)) : Date()
        let end: Date? = isPaused ? Date() : nil
        let savedSession = PinpointSession(sessionId: "stored", startTime: start, stopTime: end)
        
        userDefaults.mockedValue = Data()
        archiver.decoded = savedSession
    }
    
    func testRetrieveStoredSessionWithoutSavedSession() {
        XCTAssertEqual(userDefaults.dataForKeyCount, 1)
        XCTAssertEqual(archiver.decodeCount, 0)
    }
    
    func testRetrieveStoredSession() {
        // Validate SessionClient created without a stored Session
        XCTAssertEqual(userDefaults.dataForKeyCount, 1)
        XCTAssertEqual(archiver.decodeCount, 0)

        // Validate SessionClient created with a stored Session
        storeSession()
        createNewSessionClient()
        
        XCTAssertEqual(userDefaults.dataForKeyCount, 2)
        XCTAssertEqual(archiver.decodeCount, 1)
    }
    
    func testCurrentSession_withoutStoredSession_shouldStartNewSession() async {
        let currentSession = client.currentSession
        XCTAssertFalse(currentSession.isPaused)
        XCTAssertNil(currentSession.stopTime)
        XCTAssertEqual(archiver.encodeCount, 1)
        XCTAssertEqual(activityTracker.beginActivityTrackingCount, 0)
        XCTAssertEqual(userDefaults.saveCount, 1)
        await analyticsClient.setRecordExpectation(expectation(description: "Started new session event"))
        await waitForExpectations(timeout: 1)
        XCTAssertEqual(endpointClient.updateEndpointProfileCount, 1)
        let createEventCount = await analyticsClient.createEventCount
        XCTAssertEqual(createEventCount, 1)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 1)
    }
    
    func testCurrentSession_withStoredSession_shouldNotStartNewSession() async {
        storeSession()
        createNewSessionClient()
        
        let currentSession = client.currentSession
        XCTAssertFalse(currentSession.isPaused)
        XCTAssertNil(currentSession.stopTime)
        XCTAssertEqual(archiver.encodeCount, 0)
        XCTAssertEqual(activityTracker.beginActivityTrackingCount, 0)
        XCTAssertEqual(userDefaults.saveCount, 0)
    }
    
    func testValidateSession_withValidSession_andStoredSession_shouldReturnValidSession() async {
        storeSession()
        await resetCounters()
        let session = PinpointSession(sessionId: "valid", startTime: Date(), stopTime: nil)
        let retrievedSession = client.validateOrRetrieveSession(session)
        
        XCTAssertEqual(userDefaults.dataForKeyCount, 0)
        XCTAssertEqual(archiver.decodeCount, 0)
        XCTAssertEqual(retrievedSession.sessionId, "valid")
    }
   
    func testValidateSession_withInvalidSession_andStoredSession_shouldReturnStoredSession() async {
        storeSession()
        await resetCounters()
        let session = PinpointSession(sessionId: "", startTime: Date(), stopTime: nil)
        let retrievedSession = client.validateOrRetrieveSession(session)
        
        XCTAssertEqual(userDefaults.dataForKeyCount, 1)
        XCTAssertEqual(archiver.decodeCount, 1)
        XCTAssertEqual(retrievedSession.sessionId, "stored")
    }
    
    func testValidateSession_withInvalidSession_andWithoutStoredSession_shouldCreateDefaultSession() async {
        await resetCounters()
        let session = PinpointSession(sessionId: "", startTime: Date(), stopTime: nil)
        let retrievedSession = client.validateOrRetrieveSession(session)
        
        XCTAssertEqual(userDefaults.dataForKeyCount, 1)
        XCTAssertEqual(archiver.decodeCount, 0)
        XCTAssertEqual(retrievedSession.sessionId, PinpointSession.Constants.defaultSessionId)
    }
    
    func testValidateSession_withNilSession_andWithoutStoredSession_shouldCreateDefaultSession() async {
        await resetCounters()
        let retrievedSession = client.validateOrRetrieveSession(nil)
        
        XCTAssertEqual(userDefaults.dataForKeyCount, 1)
        XCTAssertEqual(archiver.decodeCount, 0)
        XCTAssertEqual(retrievedSession.sessionId, PinpointSession.Constants.defaultSessionId)
    }
    
    func testStartPinpointSession_shouldRecordStartEvent() async {
        await resetCounters()

        client.startPinpointSession()
        await analyticsClient.setRecordExpectation(expectation(description: "Started new session event"))
        await waitForExpectations(timeout: 1)
        XCTAssertEqual(endpointClient.updateEndpointProfileCount, 1)
        let createCount = await analyticsClient.createEventCount
        XCTAssertEqual(createCount, 1)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 1)
        guard let event = await analyticsClient.lastRecordedEvent else {
            XCTFail("Expected recorded event")
            return
        }
        XCTAssertEqual(event.eventType, SessionClient.Constants.Events.start)
    }
    
    func testStartPinpointSession_withExistingSession_shouldRecordStopEvent() async {
        storeSession()
        createNewSessionClient()
        await resetCounters()

        client.startPinpointSession()
        await analyticsClient.setRecordExpectation(expectation(description: "Stop current session and start new one events"), count: 2)
        await waitForExpectations(timeout: 1)
        let createCount = await analyticsClient.createEventCount
        XCTAssertEqual(createCount, 2)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 2)
        let events = await analyticsClient.recordedEvents
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].eventType, SessionClient.Constants.Events.stop)
        XCTAssertEqual(events[1].eventType, SessionClient.Constants.Events.start)
    }
    
    func testApplicationMovedToBackground_notStale_shouldSaveSession_andRecordPauseEvent() async {
        client.startPinpointSession()
        await analyticsClient.setRecordExpectation(expectation(description: "Start event"))
        await waitForExpectations(timeout: 1)
        
        await resetCounters()
        await analyticsClient.setRecordExpectation(expectation(description: "Pause event"))
        activityTracker.callback?(.runningInBackground(isStale: false))
        await waitForExpectations(timeout: 1)
        
        XCTAssertEqual(archiver.encodeCount, 1)
        XCTAssertEqual(userDefaults.saveCount, 1)
        let createCount = await analyticsClient.createEventCount
        XCTAssertEqual(createCount, 1)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 1)
        guard let event = await analyticsClient.lastRecordedEvent else {
            XCTFail("Expected recorded event")
            return
        }
        XCTAssertEqual(event.eventType, SessionClient.Constants.Events.pause)
    }
    
    func testApplicationMovedToBackground_stale_shouldRecordStopEvent_andSubmit() async {
        client.startPinpointSession()
        await analyticsClient.setRecordExpectation(expectation(description: "Start event"))
        await waitForExpectations(timeout: 1)
        
        await resetCounters()
        await analyticsClient.setRecordExpectation(expectation(description: "Stop event"))
        await analyticsClient.setSubmitEventsExpectation(expectation(description: "Submit events"))
        activityTracker.callback?(.runningInBackground(isStale: true))
        await waitForExpectations(timeout: 1)
        
        XCTAssertEqual(archiver.encodeCount, 0)
        XCTAssertEqual(userDefaults.saveCount, 0)
        let createCount = await analyticsClient.createEventCount
        XCTAssertEqual(createCount, 1)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 1)
        guard let event = await analyticsClient.lastRecordedEvent else {
            XCTFail("Expected recorded event")
            return
        }
        XCTAssertEqual(event.eventType, SessionClient.Constants.Events.stop)
        let submitCount = await analyticsClient.submitEventsCount
        XCTAssertEqual(submitCount, 1)
    }
    
    func testApplicationMovedToForeground_withNonPausedSession_shouldDoNothing() async {
        client.startPinpointSession()
        await analyticsClient.setRecordExpectation(expectation(description: "Start event"))
        await waitForExpectations(timeout: 1)
        
        await resetCounters()
        activityTracker.callback?(.runningInForeground)
        XCTAssertEqual(archiver.encodeCount, 0)
        XCTAssertEqual(userDefaults.saveCount, 0)
        let createCount = await analyticsClient.createEventCount
        XCTAssertEqual(createCount, 0)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 0)
        let event = await analyticsClient.lastRecordedEvent
        XCTAssertNil(event)
    }
    
    func testApplicationMovedToForeground_withNonExpiredSession_shouldRecordResumeEvent() async {
        sessionTimeout = 1000
        createNewSessionClient()
        client.startPinpointSession()
        
        // First pause the session
        activityTracker.callback?(.runningInBackground(isStale: false))
        await analyticsClient.setRecordExpectation(expectation(description: "Start and Pause event"), count: 2)
        await waitForExpectations(timeout: 1)

        
        await resetCounters()
        await analyticsClient.setRecordExpectation(expectation(description: "Pause event"))
        activityTracker.callback?(.runningInForeground)
        await waitForExpectations(timeout: 1)
        
        XCTAssertEqual(archiver.encodeCount, 1)
        XCTAssertEqual(userDefaults.saveCount, 1)
        let createCount = await analyticsClient.createEventCount
        XCTAssertEqual(createCount, 1)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 1)
        guard let event = await analyticsClient.lastRecordedEvent else {
            XCTFail("Expected recorded event")
            return
        }
        XCTAssertEqual(event.eventType, SessionClient.Constants.Events.resume)
    }
    
    func testApplicationMovedToForeground_withExpiredSession_shouldStartNewSession() async {
        sessionTimeout = 0
        createNewSessionClient()
        client.startPinpointSession()
        
        // First pause the session
        activityTracker.callback?(.runningInBackground(isStale: false))
        await analyticsClient.setRecordExpectation(expectation(description: "Start and Pause event"), count: 2)
        await waitForExpectations(timeout: 1)

        let events2 = await analyticsClient.recordedEvents
        print("EVENTS: \(events2.map({$0.eventType}))")
        
        await resetCounters()
        await analyticsClient.setRecordExpectation(expectation(description: "Stop and Start event"), count: 2)
        activityTracker.callback?(.runningInForeground)
        await waitForExpectations(timeout: 1)
        
        XCTAssertEqual(archiver.encodeCount, 1)
        XCTAssertEqual(userDefaults.saveCount, 1)
        let createCount = await analyticsClient.createEventCount
        XCTAssertEqual(createCount, 2)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 2)
        let events = await analyticsClient.recordedEvents
        XCTAssertEqual(events.count, 2)
        guard events.count == 2 else {
            return
        }
        XCTAssertEqual(events[0].eventType, SessionClient.Constants.Events.stop)
        XCTAssertEqual(events[1].eventType, SessionClient.Constants.Events.start)
    }
       
    func testApplicationTerminated_shouldRecordStopEvent() async {
        client.startPinpointSession()
        await analyticsClient.setRecordExpectation(expectation(description: "Start event"))
        await waitForExpectations(timeout: 1)
        
        await resetCounters()
        await analyticsClient.setRecordExpectation(expectation(description: "Stop event"))
        activityTracker.callback?(.terminated)
        await waitForExpectations(timeout: 1)
        
        XCTAssertEqual(archiver.encodeCount, 0)
        XCTAssertEqual(userDefaults.saveCount, 0)
        let createCount = await analyticsClient.createEventCount
        XCTAssertEqual(createCount, 1)
        let recordCount = await analyticsClient.recordCount
        XCTAssertEqual(recordCount, 1)
        guard let event = await analyticsClient.lastRecordedEvent else {
            XCTFail("Expected recorded event")
            return
        }
        XCTAssertEqual(event.eventType, SessionClient.Constants.Events.stop)
        let submitCount = await analyticsClient.submitEventsCount
        XCTAssertEqual(submitCount, 0)
    }
}
        

class MockArchiver: AmplifyArchiverBehaviour {
    var encoded: Data = Data()
    var decoded: Decodable?
    
    func resetCounters() {
        encodeCount = 0
        decodeCount = 0
    }
    
    var encodeCount = 0
    func encode<T>(_ encodable: T) throws -> Data where T : Encodable {
        encodeCount += 1
        return encoded
    }
    
    var decodeCount = 0
    func decode<T>(_ decodable: T.Type, from data: Data) throws -> T? where T : Decodable {
        decodeCount += 1
        return decoded as? T
    }
}

class MockActivityTracker: ActivityTrackerBehaviour {
    var beginActivityTrackingCount = 0
    var callback: ((ApplicationState) -> Void)?
    
    func beginActivityTracking(_ listener: @escaping (ApplicationState) -> Void) {
        beginActivityTrackingCount += 1
        callback = listener
    }
    
    func resetCounters() {
        beginActivityTrackingCount = 0
    }
}

class MockUserDefaults: UserDefaultsBehaviour {
    private var data: [String: UserDefaultsBehaviourValue] = [:]
    var mockedValue: UserDefaultsBehaviourValue?
    
    var saveCount = 0
    func save(_ value: UserDefaultsBehaviourValue?, forKey key: String) {
        saveCount += 1
        data[key] = value
    }
    
    func removeObject(forKey key: String) {
        data[key] = nil
    }
    
    var stringForKeyCount = 0
    func string(forKey key: String) -> String? {
        stringForKeyCount += 1
        if let stored = data[key] as? String {
            return stored
        }
        return mockedValue as? String
    }
    
    var dataForKeyCount = 0
    func data(forKey key: String) -> Data? {
        dataForKeyCount += 1
        if let stored = data[key] as? Data {
            return stored
        }
        return mockedValue as? Data
    }
    
    func resetCounters() {
        saveCount = 0
        dataForKeyCount = 0
        stringForKeyCount = 0
    }
}


import StoreKit

actor MockAnalyticsClient: AnalyticsClientBehaviour {
    func addGlobalAttribute(_ attribute: String, forKey key: String) {}
    func addGlobalAttribute(_ attribute: String, forKey key: String, forEventType eventType: String) {}
    func addGlobalMetric(_ metric: Double, forKey key: String) {}
    func addGlobalMetric(_ metric: Double, forKey key: String, forEventType eventType: String) {}
    func removeGlobalAttribute(forKey key: String) {}
    func removeGlobalAttribute(forKey key: String, forEventType eventType: String) {}
    func removeGlobalMetric(forKey key: String) {}
    func removeGlobalMetric(forKey key: String, forEventType eventType: String) {}
    
    nonisolated func createAppleMonetizationEvent(with transaction: SKPaymentTransaction, with product: SKProduct) -> PinpointEvent {
        return PinpointEvent(eventType: "Apple", session: PinpointSession(appId: "", uniqueId: ""))
    }
    
    nonisolated func createVirtualMonetizationEvent(withProductId productId: String, withItemPrice itemPrice: Double, withQuantity quantity: Int, withCurrency currency: String) -> PinpointEvent {
        return PinpointEvent(eventType: "Virtual", session: PinpointSession(appId: "", uniqueId: ""))
    }
    
    var createEventCount = 0
    private func increaseCreateEventCount() {
        createEventCount += 1
    }

    nonisolated func createEvent(withEventType eventType: String) -> PinpointEvent {
        Task {
            await increaseCreateEventCount()
        }
        return PinpointEvent(eventType: eventType, session: PinpointSession(appId: "", uniqueId: ""))
    }
    
    private var recordExpectation: XCTestExpectation?
    func setRecordExpectation(_ expectation: XCTestExpectation, count: Int = 1) {
        recordExpectation = expectation
        recordExpectation?.expectedFulfillmentCount = count
    }

    var recordCount = 0
    var lastRecordedEvent: PinpointEvent?
    var recordedEvents: [PinpointEvent] = []
    func record(_ event: PinpointEvent) async throws {
        recordCount += 1
        lastRecordedEvent = event
        recordedEvents.append(event)
        recordExpectation?.fulfill()
    }
    
    
    private var submitEventsExpectation: XCTestExpectation?
    func setSubmitEventsExpectation(_ expectation: XCTestExpectation, count: Int = 1) {
        submitEventsExpectation = expectation
        submitEventsExpectation?.expectedFulfillmentCount = count
    }

    var submitEventsCount = 0
    func submitEvents() async throws -> [PinpointEvent] {
        submitEventsCount += 1
        submitEventsExpectation?.fulfill()
        return []
    }
    
    func resetCounters() {
        recordCount = 0
        submitEventsCount = 0
        createEventCount = 0
        recordedEvents = []
        lastRecordedEvent = nil
    }
}

class MockEndpointClient: EndpointClient {
    init() {
        let context = try! PinpointContext(with: PinpointContextConfiguration(appId: "appId"),
                                           credentialsProvider: MockCredentialsProvider(),
                                           region: "region")
        super.init(context: context)
    }
    
    class MockCredentialsProvider: CredentialsProvider {
        func getCredentials() async throws -> AWSCredentials {
            return AWSCredentials(accessKey: "", secret: "", expirationTimeout: 1000)
        }
    }
    
    var updateEndpointProfileCount = 0
    override func updateEndpointProfile() async throws {
        updateEndpointProfileCount += 1
    }
    
    func resetCounters() {
        updateEndpointProfileCount = 0
    }
}
