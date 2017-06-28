import Foundation
import CoreLocation
import MapboxDirections
import Mapbox
import Polyline

/**
 The `RouteControllerDelegate` class provides methods for responding to significant occasions during the user’s traversal of a route monitored by a `RouteController`.
 */
@objc(MBRouteControllerDelegate)
public protocol RouteControllerDelegate: class {
    /**
     Returns whether the route controller should be allowed to calculate a new route.
     
     If implemented, this method is called as soon as the route controller detects that the user is off the predetermined route. Implement this method to conditionally prevent rerouting. If this method returns `true`, `routeController(_:willRerouteFrom:)` will be called immediately afterwards.
     
     - parameter routeController: The route controller that has detected the need to calculate a new route.
     - parameter location: The user’s current location.
     - returns: True to allow the route controller to calculate a new route; false to keep tracking the current route.
     */
    @objc(routeController:shouldRerouteFromLocation:)
    optional func routeController(_ routeController: RouteController, shouldRerouteFrom location: CLLocation) -> Bool
    
    /**
     Called immediately before the route controller calculates a new route.
     
     This method is called after `routeController(_:shouldRerouteFrom:)` is called, simultaneously with the `RouteControllerWillReroute` notification being posted, and before `routeController(_:didRerouteAlong:)` is called.
     
     - parameter routeController: The route controller that will calculate a new route.
     - parameter location: The user’s current location.
     */
    @objc(routeController:willRerouteFromLocation:)
    optional func routeController(_ routeController: RouteController, willRerouteFrom location: CLLocation)
    
    /**
     Called immediately after the route controller receives a new route.
     
     This method is called after `routeController(_:willRerouteFrom:)` and simultaneously with the `RouteControllerDidReroute` notification being posted.
     
     - parameter routeController: The route controller that has calculated a new route.
     - parameter route: The new route.
     */
    @objc(routeController:didRerouteAlongRoute:)
    optional func routeController(_ routeController: RouteController, didRerouteAlong route: Route)
    
    /**
     Called when the route controller fails to receive a new route.
     
     This method is called after `routeController(_:willRerouteFrom:)` and simultaneously with the `RouteControllerDidFailToReroute` notification being posted.
     
     - parameter routeController: The route controller that has calculated a new route.
     - parameter error: An error raised during the process of obtaining a new route.
     */
    @objc(routeController:didFailToRerouteWithError:)
    optional func routeController(_ routeController: RouteController, didFailToRerouteWith error: Error)
    
    /**
     Called when the route controller’s location manager receive a location update.
     
     These locations can be modified due to replay or simulation but they can
     also derive from regular location updates from a `CLLocationManager`.
     
     - parameter routeController: The route controller that received the new locations.
     - parameter locations: The locations that were received from the associated location manager.
     */
    @objc(routeController:didUpdateLocations:)
    optional func routeController(_ routeController: RouteController, didUpdateLocations locations: [CLLocation])
}

/**
 A `RouteController` tracks the user’s progress along a route, posting notifications as the user reaches significant points along the route. On every location update, the route controller evaluates the user’s location, determining whether the user remains on the route. If not, the route controller calculates a new route.
 */
@objc(MBRouteController)
open class RouteController: NSObject {
    
    var lastUserDistanceToStartOfRoute = Double.infinity
    
    var lastTimeStampSpentMovingAwayFromStart = Date()
    
    /**
     The route controller’s delegate.
     */
    public weak var delegate: RouteControllerDelegate?
    
    /**
     The Directions object used to create the route.
     */
    public let directions: Directions
    
    /**
     The route controller’s associated location manager.
     */
    public var locationManager: NavigationLocationManager!
    
    /**
     If true, location updates will be simulated when driving through tunnels or
     other areas where there is none or bad GPS reception.
     */
    public var isDeadReckoningEnabled = false
    
    /**
     Details about the user’s progress along the current route, leg, and step.
     */
    public var routeProgress: RouteProgress {
        willSet {
            // Save any progress completed up until now
            sessionState.totalDistanceCompleted += routeProgress.distanceTraveled
        }
        didSet {
            sessionState.currentRoute = routeProgress.route

            var userInfo = [String: Any]()
            if let location = locationManager.location {
                userInfo[MBRouteControllerNotificationLocationKey] = location
            }
            NotificationCenter.default.post(name: RouteControllerDidReroute, object: self, userInfo: userInfo)
        }
    }
    
    /**
     If true, the user puck is snapped to closest location on the route.
     */
    public var snapsUserLocationAnnotationToRoute = true
    
    var isRerouting = false
    
    var routeTask: URLSessionDataTask?
    
    /**
     Intializes a new `RouteController`.
     
     - parameter route: The route to follow.
     - parameter directions: The Directions object that created `route`.
     - parameter locationManager: The associated location manager.
     */
    @objc(initWithRoute:directions:locationManager:)
    public init(along route: Route, directions: Directions = Directions.shared, locationManager: NavigationLocationManager = NavigationLocationManager()) {
        self.directions = directions
        self.routeProgress = RouteProgress(route: route)
        self.locationManager = locationManager
        self.locationManager.activityType = route.routeOptions.activityType
        super.init()
        
        self.locationManager.delegate = self
        
        self.sessionState.originalRoute = route
        self.sessionState.currentRoute = route
        
        self.resumeNotifications()
    }
    
    /// :nodoc:
    public var usesDefaultUserInterface = false
    
    var sessionState = SessionState()
    var outstandingFeedbackEvents = [CoreFeedbackEvent]()
    
    deinit {
        suspendLocationUpdates()
        checkAndSendOutstandingFeedbackEvents(forceAll: true)
        sendCancelEvent()
        suspendNotifications()
    }
    
    func resumeNotifications() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(progressDidChange(notification:)), name: RouteControllerProgressDidChange, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(alertLevelDidChange(notification:)), name: RouteControllerAlertLevelDidChange, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(willReroute(notification:)), name: RouteControllerWillReroute, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(didReroute(notification:)), name: RouteControllerDidReroute, object: self)
    }
    
    func suspendNotifications() {
        UIDevice.current.isBatteryMonitoringEnabled = false
        NotificationCenter.default.removeObserver(self)
    }
    
    /**
     Starts monitoring the user’s location along the route.
     
     Will continue monitoring until `suspendLocationUpdates()` is called.
     */
    public func resume() {
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }
    
    /**
     Stops monitoring the user’s location along the route.
     */
    public func suspendLocationUpdates() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }
    
    /**
     Send feedback about the current road segment/maneuver to the Mapbox data team.
     
     You can hook this up to a custom feedback UI in your app to flag problems during navigation
     such as road closures, incorrect instructions, etc. 
     
     With the help of a custom `description` to elaborate on the nature of the problem, using
     this function will automatically flag the road segment/maneuver the user is currently on for 
     closer inspection by Mapbox's system and team.
     */
    public func sendFeedback(type: FeedbackType, description: String?) {
        enqueueFeedbackEvent(type: type, description: description)
    }
}

extension RouteController {
    func progressDidChange(notification: NSNotification) {
        if sessionState.departureTimestamp == nil {
            sessionState.departureTimestamp = Date()
            sendDepartEvent()
        }
        checkAndSendOutstandingFeedbackEvents()
    }
    
    func alertLevelDidChange(notification: NSNotification) {
        let alertLevel = routeProgress.currentLegProgress.alertUserLevel
        if alertLevel == .arrive && sessionState.arrivalTimestamp == nil {
            sessionState.arrivalTimestamp = Date()
            sendArriveEvent()
        }
    }
    
    func willReroute(notification: NSNotification) {
        enqueueRerouteEvent()
    }
    
    func didReroute(notification: NSNotification) {
        let route = routeProgress.route
        if let lastReroute = outstandingFeedbackEvents.filter({$0 is RerouteEvent }).last {
            if let geometry = route.coordinates {
                lastReroute.eventDictionary["newGeometry"] = Polyline(coordinates: geometry).encodedPolyline
                lastReroute.eventDictionary["newDistanceRemaining"] = route.distance
                lastReroute.eventDictionary["newDurationRemaining"] = route.expectedTravelTime
            }
        }
    }
}

extension RouteController: CLLocationManagerDelegate {
    
    func interpolateLocation() {
        guard let location = locationManager.lastKnownLocation else { return }
        guard let polyline = routeProgress.route.coordinates else { return }
        
        let distance = location.speed as CLLocationDistance
        
        guard let interpolatedCoordinate = coordinate(at: routeProgress.distanceTraveled+distance, fromStartOf: polyline) else {
            return
        }
        
        var course = location.course
        if let upcomingCoordinate = coordinate(at: routeProgress.distanceTraveled+(distance*2), fromStartOf: polyline) {
            course = interpolatedCoordinate.direction(to: upcomingCoordinate)
        }
        
        let interpolatedLocation = CLLocation(coordinate: interpolatedCoordinate,
                                              altitude: location.altitude,
                                              horizontalAccuracy: location.horizontalAccuracy,
                                              verticalAccuracy: location.verticalAccuracy,
                                              course: course,
                                              speed: location.speed,
                                              timestamp: Date())
        
        self.locationManager(self.locationManager, didUpdateLocations: [interpolatedLocation])
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        
        delegate?.routeController?(self, didUpdateLocations: [location])
        
        sessionState.pastLocations.push(location)

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(interpolateLocation), object: nil)
        
        if isDeadReckoningEnabled {
            perform(#selector(interpolateLocation), with: nil, afterDelay: 1.1)
        }
        
        let userSnapToStepDistanceFromManeuver = distance(along: routeProgress.currentLegProgress.currentStep.coordinates!, from: location.coordinate)
        let secondsToEndOfStep = userSnapToStepDistanceFromManeuver / location.speed
        
        guard routeProgress.currentLegProgress.alertUserLevel != .arrive else {
            // Don't advance nor check progress if the user has arrived at their destination
            suspendLocationUpdates()
            NotificationCenter.default.post(name: RouteControllerProgressDidChange, object: self, userInfo: [
                RouteControllerProgressDidChangeNotificationProgressKey: routeProgress,
                RouteControllerProgressDidChangeNotificationLocationKey: location,
                RouteControllerProgressDidChangeNotificationSecondsRemainingOnStepKey: secondsToEndOfStep
                ])
            return
        }
        
        // Notify observers if the step’s remaining distance has changed.
        let currentStepProgress = routeProgress.currentLegProgress.currentStepProgress
        let currentStep = currentStepProgress.step
        if let closestCoordinate = closestCoordinate(on: currentStep.coordinates!, to: location.coordinate) {
            let remainingDistance = distance(along: currentStep.coordinates!, from: closestCoordinate.coordinate)
            let distanceTraveled = currentStep.distance - remainingDistance
            if distanceTraveled != currentStepProgress.distanceTraveled {
                currentStepProgress.distanceTraveled = distanceTraveled
                NotificationCenter.default.post(name: RouteControllerProgressDidChange, object: self, userInfo: [
                    RouteControllerProgressDidChangeNotificationProgressKey: routeProgress,
                    RouteControllerProgressDidChangeNotificationLocationKey: location,
                    RouteControllerProgressDidChangeNotificationSecondsRemainingOnStepKey: secondsToEndOfStep
                    ])
            }
        }
        
        let step = routeProgress.currentLegProgress.currentStepProgress.step
        if step.maneuverType == .depart && !userIsOnRoute(location) {
            
            guard let userSnappedDistanceToClosestCoordinate = closestCoordinate(on: step.coordinates!, to: location.coordinate)?.distance else {
                return
            }
            
            // Give the user x seconds of moving away from the start of the route before rerouting
            guard Date().timeIntervalSince(lastTimeStampSpentMovingAwayFromStart) > MaxSecondsSpentTravelingAwayFromStartOfRoute else {
                lastUserDistanceToStartOfRoute = userSnappedDistanceToClosestCoordinate
                return
            }
            
            // Don't check `userIsOnRoute` if the user has not moved
            guard userSnappedDistanceToClosestCoordinate != lastUserDistanceToStartOfRoute else {
                lastUserDistanceToStartOfRoute = userSnappedDistanceToClosestCoordinate
                return
            }
            
            if userSnappedDistanceToClosestCoordinate > lastUserDistanceToStartOfRoute {
                lastTimeStampSpentMovingAwayFromStart = location.timestamp
            }
            
            lastUserDistanceToStartOfRoute = userSnappedDistanceToClosestCoordinate
        }
        
        guard userIsOnRoute(location) || !(delegate?.routeController?(self, shouldRerouteFrom: location) ?? true) else {
            reroute(from: location)
            return
        }
        
        monitorStepProgress(location)
    }
    
    func resetStartCounter() {
        lastTimeStampSpentMovingAwayFromStart = Date()
        lastUserDistanceToStartOfRoute = Double.infinity
    }
    
    /**
     Given a users current location, returns a Boolean whether they are currently on the route.
     
     If the user is not on the route, they should be rerouted.
     */
    public func userIsOnRoute(_ location: CLLocation) -> Bool {
        // Find future location of user
        let metersInFrontOfUser = location.speed * RouteControllerDeadReckoningTimeInterval
        let locationInfrontOfUser = location.coordinate.coordinate(at: metersInFrontOfUser, facing: location.course)
        let newLocation = CLLocation(latitude: locationInfrontOfUser.latitude, longitude: locationInfrontOfUser.longitude)
        let radius = max(RouteControllerMaximumDistanceBeforeRecalculating,
                         location.horizontalAccuracy + RouteControllerUserLocationSnappingDistance)

        let isCloseToCurrentStep = newLocation.isWithin(radius, of: routeProgress.currentLegProgress.currentStep)
        
        // If the user is moving away from the maneuver location
        // and they are close to the next step
        // we can safely say they have completed the maneuver.
        // This is intended to be a fallback case when we do find
        // that the users course matches the exit bearing.
        if let upComingStep = routeProgress.currentLegProgress.upComingStep {
            let isCloseToUpComingStep = newLocation.isWithin(radius, of: upComingStep)
            if !isCloseToCurrentStep && isCloseToUpComingStep {
                let userSnapToStepDistanceFromManeuver = distance(along: upComingStep.coordinates!, from: location.coordinate)
                let secondsToEndOfStep = userSnapToStepDistanceFromManeuver / location.speed
                incrementRouteProgress(secondsToEndOfStep <= RouteControllerMediumAlertInterval ? .medium : .low, location: location, updateStepIndex: true)
                return true
            }
        }
        
        return isCloseToCurrentStep
    }
    
    func incrementRouteProgress(_ newlyCalculatedAlertLevel: AlertLevel, location: CLLocation, updateStepIndex: Bool) {
        
        if updateStepIndex {
            routeProgress.currentLegProgress.stepIndex += 1
        }
        
        // If the step is not being updated, don't accept a lower alert level.
        // A lower alert level can only occur when the user begins the next step.
        guard newlyCalculatedAlertLevel.rawValue > routeProgress.currentLegProgress.alertUserLevel.rawValue || updateStepIndex else {
            return
        }
        
        if routeProgress.currentLegProgress.alertUserLevel != newlyCalculatedAlertLevel {
            routeProgress.currentLegProgress.alertUserLevel = newlyCalculatedAlertLevel
            // Use fresh user location distance to end of step
            // since the step could of changed
            let userDistance = distance(along: routeProgress.currentLegProgress.currentStep.coordinates!, from: location.coordinate)
            
            NotificationCenter.default.post(name: RouteControllerAlertLevelDidChange, object: self, userInfo: [
                RouteControllerAlertLevelDidChangeNotificationRouteProgressKey: routeProgress,
                RouteControllerAlertLevelDidChangeNotificationDistanceToEndOfManeuverKey: userDistance
                ])
        }
    }
    
    func reroute(from location: CLLocation) {
        if isRerouting {
            return
        }
        
        isRerouting = true
        
        resetStartCounter()
        delegate?.routeController?(self, willRerouteFrom: location)
        NotificationCenter.default.post(name: RouteControllerWillReroute, object: self, userInfo: [
            MBRouteControllerNotificationLocationKey: location
            ])
        
        routeTask?.cancel()
        
        let options = routeProgress.route.routeOptions
        
        options.waypoints = [Waypoint(coordinate: location.coordinate)] + routeProgress.remainingWaypoints
        
        if let firstWaypoint = options.waypoints.first, location.course >= 0 {
            firstWaypoint.heading = location.course
            firstWaypoint.headingAccuracy = 90
        }
        
        routeTask = directions.calculate(options, completionHandler: { [weak self] (waypoints, routes, error) in
            defer {
                self?.isRerouting = false
            }
            
            guard let strongSelf = self else {
                return
            }
            
            if let route = routes?.first {
                strongSelf.routeProgress = RouteProgress(route: route)
                strongSelf.routeProgress.currentLegProgress.stepIndex = 0
                strongSelf.delegate?.routeController?(strongSelf, didRerouteAlong: route)
            } else if let error = error {
                strongSelf.delegate?.routeController?(strongSelf, didFailToRerouteWith: error)
                NotificationCenter.default.post(name: RouteControllerDidFailToReroute, object: self, userInfo: [
                    MBRouteControllerNotificationErrorKey: error
                    ])
            }
        })
    }
    
    func monitorStepProgress(_ location: CLLocation) {
        // Force an announcement when the user begins a route
        var alertLevel: AlertLevel = routeProgress.currentLegProgress.alertUserLevel == .none ? .depart : routeProgress.currentLegProgress.alertUserLevel
        var updateStepIndex = false
        let profileIdentifier = routeProgress.route.routeOptions.profileIdentifier
        
        let userSnapToStepDistanceFromManeuver = distance(along: routeProgress.currentLegProgress.currentStep.coordinates!, from: location.coordinate)
        let secondsToEndOfStep = userSnapToStepDistanceFromManeuver / location.speed
        var courseMatchesManeuverFinalHeading = false
        
        let minimumDistanceForHighAlert = RouteControllerMinimumDistanceForHighAlert(identifier: profileIdentifier)
        let minimumDistanceForMediumAlert = RouteControllerMinimumDistanceForMediumAlert(identifier: profileIdentifier)
        
        // Bearings need to normalized so when the `finalHeading` is 359 and the user heading is 1,
        // we count this as within the `RouteControllerMaximumAllowedDegreeOffsetForTurnCompletion`
        if let finalHeading = routeProgress.currentLegProgress.upComingStep?.finalHeading {
            let finalHeadingNormalized = wrap(finalHeading, min: 0, max: 360)
            let userHeadingNormalized = wrap(location.course, min: 0, max: 360)
            courseMatchesManeuverFinalHeading = differenceBetweenAngles(finalHeadingNormalized, userHeadingNormalized) <= RouteControllerMaximumAllowedDegreeOffsetForTurnCompletion
        }

        // When departing, `userSnapToStepDistanceFromManeuver` is most often less than `RouteControllerManeuverZoneRadius`
        // since the user will most often be at the beginning of the route, in the maneuver zone
        if alertLevel == .depart && userSnapToStepDistanceFromManeuver <= RouteControllerManeuverZoneRadius {
            // If the user is close to the maneuver location,
            // don't give a depature instruction.
            // Instead, give a `.high` alert.
            if secondsToEndOfStep <= RouteControllerHighAlertInterval {
                alertLevel = .high
            }
        } else if userSnapToStepDistanceFromManeuver <= RouteControllerManeuverZoneRadius {
            // Use the currentStep if there is not a next step
            // This occurs when arriving
            let step = routeProgress.currentLegProgress.upComingStep?.maneuverLocation ?? routeProgress.currentLegProgress.currentStep.maneuverLocation
            let userAbsoluteDistance = step - location.coordinate
            
            // userAbsoluteDistanceToManeuverLocation is set to nil by default
            // If it's set to nil, we know the user has never entered the maneuver radius
            if routeProgress.currentLegProgress.currentStepProgress.userDistanceToManeuverLocation == nil {
                routeProgress.currentLegProgress.currentStepProgress.userDistanceToManeuverLocation = RouteControllerManeuverZoneRadius
            }
            
            let lastKnownUserAbsoluteDistance = routeProgress.currentLegProgress.currentStepProgress.userDistanceToManeuverLocation
            
            // The objective here is to make sure the user is moving away from the maneuver location
            // This helps on maneuvers where the difference between the exit and enter heading are similar
            if  userAbsoluteDistance <= lastKnownUserAbsoluteDistance! {
                routeProgress.currentLegProgress.currentStepProgress.userDistanceToManeuverLocation = userAbsoluteDistance
            }
            
            if routeProgress.currentLegProgress.upComingStep?.maneuverType == ManeuverType.arrive {
                alertLevel = .arrive
            } else if courseMatchesManeuverFinalHeading {
                updateStepIndex = true
                
                // Look at the following step to determine what the new alert level should be
                if let upComingStep = routeProgress.currentLegProgress.upComingStep {
                    alertLevel = upComingStep.expectedTravelTime <= RouteControllerMediumAlertInterval ? .medium : .low
                } else {
                    assert(false, "In this case, there should always be an upcoming step")
                }
            }
        } else if secondsToEndOfStep <= RouteControllerHighAlertInterval && routeProgress.currentLegProgress.currentStep.distance > minimumDistanceForHighAlert {
            alertLevel = .high
        } else if secondsToEndOfStep <= RouteControllerMediumAlertInterval &&
            // Don't alert if the route segment is shorter than X
            // However, if it's the beginning of the route
            // There needs to be an alert
            routeProgress.currentLegProgress.currentStep.distance > minimumDistanceForMediumAlert {
            alertLevel = .medium
        }
        
        incrementRouteProgress(alertLevel, location: location, updateStepIndex: updateStepIndex)
    }
}

struct SessionState {
    let identifier = UUID()
    var departureTimestamp: Date?
    var arrivalTimestamp: Date?
    
    var totalDistanceCompleted: CLLocationDistance = 0
    
    var numberOfReroutes = 0
    var lastReroute: Date?
    
    var currentRoute: Route!
    var currentRequestIdentifier: String?
    
    var originalRoute: Route!
    var originalRequestIdentifier: String?
    
    var pastLocations = FixedLengthBuffer<CLLocation>(length: 40)
}

// MARK: - Telemetry
extension RouteController {
    
    func sendDepartEvent() {
        let eventName = "navigation.depart"
        
        NSLog("Sending \(eventName)")
        
        var eventDictionary = MGLMapboxEvents.addDefaultEvents(routeController: self)
        eventDictionary["event"] = eventName

        MGLMapboxEvents.pushEvent(eventName, withAttributes: eventDictionary)
        MGLMapboxEvents.flush()
    }
    
    func sendFeedbackEvent(event: CoreFeedbackEvent) {
        // remove from outstanding event queue
        if let index = outstandingFeedbackEvents.index(of: event) {
            outstandingFeedbackEvents.remove(at: index)
        }
        
        let eventName = event.eventDictionary["event"] as! String
        
        NSLog("Sending \(eventName)")

        event.eventDictionary["locationsBefore"] = sessionState.pastLocations.allObjects.filter({$0.timestamp <= event.timestamp }).map({$0.dictionary})
        event.eventDictionary["locationsAfter"] = sessionState.pastLocations.allObjects.filter({$0.timestamp > event.timestamp }).map({$0.dictionary})
        
        MGLMapboxEvents.pushEvent(eventName, withAttributes: event.eventDictionary)
        MGLMapboxEvents.flush()
    }

    func sendArriveEvent() {
        let eventName = "navigation.arrive"
        
        var eventDictionary = MGLMapboxEvents.addDefaultEvents(routeController: self)
        eventDictionary["event"] = eventName
        
        NSLog("Sending \(eventName)")

        MGLMapboxEvents.pushEvent(eventName, withAttributes: eventDictionary)
        MGLMapboxEvents.flush()
    }
    
    func sendCancelEvent() {
        let eventName = "navigation.cancel"

        var eventDictionary = MGLMapboxEvents.addDefaultEvents(routeController: self)
        eventDictionary["event"] = eventName
        eventDictionary["arrivalTimestamp"] = sessionState.arrivalTimestamp?.ISO8601 ?? NSNull()

        NSLog("Sending \(eventName)")

        MGLMapboxEvents.pushEvent(eventName, withAttributes: eventDictionary)
        MGLMapboxEvents.flush()
    }
    
    func enqueueFeedbackEvent(type: FeedbackType, description: String?) {
        let eventName = "navigation.feedback"
        
        var eventDictionary = MGLMapboxEvents.addDefaultEvents(routeController: self)
        eventDictionary["event"] = eventName
        
        eventDictionary["feedbackType"] = type.rawValue
        eventDictionary["description"] = description
        
        outstandingFeedbackEvents.append(FeedbackEvent(timestamp: Date(), eventDictionary: eventDictionary))
    }
    
    func enqueueRerouteEvent() {
        let eventName = "navigation.reroute"

        let timestamp = Date()
        
        var eventDictionary = MGLMapboxEvents.addDefaultEvents(routeController: self)
        eventDictionary["event"] = eventName
        
        eventDictionary["secondsSinceLastReroute"] = sessionState.lastReroute != nil ? timestamp.timeIntervalSince(sessionState.lastReroute!) : -1
        
        // These are placeholders until the
        eventDictionary["newDistanceRemaining"] = -1
        eventDictionary["newDurationRemaining"] = -1
        eventDictionary["newGeometry"] = nil
        
        sessionState.lastReroute = timestamp
        sessionState.numberOfReroutes += 1
        
        outstandingFeedbackEvents.append(RerouteEvent(timestamp: timestamp, eventDictionary: eventDictionary))
    }
    
    func checkAndSendOutstandingFeedbackEvents(forceAll: Bool = false) {
        let now = Date()
        let eventsToPush = forceAll ? outstandingFeedbackEvents : outstandingFeedbackEvents.filter({now.timeIntervalSince($0.timestamp) > SECONDS_FOR_COLLECTION_AFTER_FEEDBACK_EVENT})
        for event in eventsToPush {
            sendFeedbackEvent(event: event)
        }
    }
}
