import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../services/distress_monitor.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:iconsax/iconsax.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/routing_service.dart';
import '../services/sos_service.dart';
import 'location_picker_screen.dart';

class CompanionModeScreen extends StatefulWidget {
  const CompanionModeScreen({super.key});

  @override
  State<CompanionModeScreen> createState() => _CompanionModeScreenState();
}

class _CompanionModeScreenState extends State<CompanionModeScreen> {
  // ─── CONFIGURABLE CONSTANTS ───────────────────────────────────────────────
  static const double deviationThresholdMeters = 40.0; // Allowed road buffer
  static const double minGpsAccuracyMeters = 60.0; // Allow practical outdoor GPS fixes
  static const int deviationPersistenceCount = 2; // Fast: 2 consecutive off-route fixes
  static const double arrivalRadiusMeters = 50.0; // Arrival radius
  static const Duration deviationAlertCooldown = Duration(minutes: 3);

  // ─── CONTROLLERS & MAP ─────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final SosService _sosService = SosService();

  // ─── STATE: LOCATIONS & ADDRESSES ──────────────────────────────────────────
  LatLng? _startLocation;
  String _startAddress = 'Detecting current location…';

  LatLng? _currentLocation;
  Position? _lastPosition;

  LatLng? _destination;
  String _destinationAddress = '';

  // ─── STATE: ROUTING ────────────────────────────────────────────────────────
  RouteInfo? _routeInfo;
  List<RouteInfo> _availableRoutes = [];
  int _selectedRouteIndex = 0;
  List<LatLng> _routePoints = [];
  bool _isCalculatingRoute = false;
  double _remainingDistanceMeters = 0.0;
  String _remainingDurationText = '';

  String get _elapsedTimeString {
    if (_startedAt == null) return '0m';
    final elapsed = DateTime.now().difference(_startedAt!);
    final m = elapsed.inMinutes;
    final s = elapsed.inSeconds % 60;
    return '${m}m ${s}s';
  }

  // ─── STATE: SEARCH AUTOCOMPLETE ────────────────────────────────────────────
  List<PlaceSuggestion> _suggestions = [];
  bool _isSearching = false;
  Timer? _searchDebounceTimer;

  // ─── STATE: TRACKING & BACKGROUND ──────────────────────────────────────────
  bool _isActive = false;
  bool _autoFollowUser = true;
  String? _sessionId;
  DateTime? _startedAt;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<Position>? _preStartSubscription;
  Timer? _firestoreSyncTimer;
  int _updatesPushed = 0;
  double _userHeading = 0.0;

  // ─── STATE: ROUTE DEVIATION & ALERTS ───────────────────────────────────────
  int _consecutiveDeviationCount = 0;
  bool _isDeviationActive = false;
  DateTime? _lastDeviationAlertTime;

  // ─── STATE: USER PROFILE ───────────────────────────────────────────────────
  String _userName = 'SafetyGuardian User';

  @override
  void initState() {
    super.initState();
    _fetchUserProfile();
    _initStartLocation();
    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus && mounted) {
        setState(() {
          _suggestions = [];
          _isSearching = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _positionSubscription?.cancel();
    _preStartSubscription?.cancel();
    _firestoreSyncTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _stopForegroundService();
    super.dispose();
  }

  // ─── 1. INITIALIZE USER & DETECT START LOCATION AUTOMATICALLY ──────────────
  Future<void> _fetchUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final name = data['name']?.toString() ?? data['fullName']?.toString();
        if (name != null && name.isNotEmpty) {
          _userName = name;
          return;
        }
      }
      if (user.displayName != null && user.displayName!.isNotEmpty) {
        _userName = user.displayName!;
      } else if (user.email != null) {
        _userName = user.email!.split('@').first;
      }
    } catch (_) {}
  }

  Future<void> _initStartLocation() async {
    // Check if location services are enabled
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        _showGpsDisabledDialog();
      }
      return;
    }

    // Check & request permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          _showSnackBar('Location permission is required for Companion Mode', Colors.red);
        }
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        _showPermissionDeniedForeverDialog();
      }
      return;
    }

    // Proactively request SMS & Phone permissions as soon as Companion Mode opens
    // so system permission prompts appear right away before starting a trip
    try {
      if (!await Permission.sms.isGranted) {
        await Permission.sms.request();
      }
      if (!await Permission.phone.isGranted) {
        await Permission.phone.request();
      }
    } catch (e) {
      debugPrint('Error requesting initial SMS/phone permission: $e');
    }

    // 1. Try to get last known position immediately for instant map centering
    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && mounted && _startLocation == null) {
        final lastLatLng = LatLng(lastKnown.latitude, lastKnown.longitude);
        setState(() {
          _lastPosition = lastKnown;
          _startLocation = lastLatLng;
          _currentLocation = lastLatLng;
        });
        _reverseGeocodeStart(lastLatLng);
        _mapController.move(lastLatLng, 15);
      }
    } catch (_) {}

    // 2. Fetch fresh high-accuracy GPS position
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));

      final userLatLng = LatLng(pos.latitude, pos.longitude);

      if (!mounted) return;
      setState(() {
        _lastPosition = pos;
        _startLocation = userLatLng;
        _currentLocation = userLatLng;
      });

      _reverseGeocodeStart(userLatLng);

      _mapController.move(userLatLng, 15);

      // Pre-start location listener to keep start location live until trip starts
      _preStartSubscription?.cancel();
      _preStartSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((p) {
        if (!mounted || _isActive) return;
        final liveLoc = LatLng(p.latitude, p.longitude);
        setState(() {
          _lastPosition = p;
          _startLocation = liveLoc;
          _currentLocation = liveLoc;
        });
      });
    } catch (e) {
      debugPrint('Error getting start location: $e');
      if (mounted && _startLocation == null) {
        _showSnackBar('Could not fetch GPS location. Please check your signal.', Colors.orange);
      }
    }
  }

  Future<void> _reverseGeocodeStart(LatLng pos) async {
    try {
      final addr = await RoutingService.reverseGeocode(pos);
      if (!mounted) return;
      setState(() {
        _startAddress = addr;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _startAddress = 'Location (${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)})';
      });
    }
  }

  // ─── 2. DESTINATION SEARCH, MAP TAP & AUTOCOMPLETE ─────────────────────────
  Future<void> _handleMapTap(LatLng point) async {
    if (_isActive) return;
    _searchFocusNode.unfocus();

    if (_suggestions.isNotEmpty) {
      setState(() => _suggestions = []);
    }

    // 1. If alternative routes exist, check if user tapped close to any route to switch it
    if (_availableRoutes.length > 1) {
      int bestIndex = -1;
      double minDistance = 120.0; // 120 meters tap tolerance

      for (int i = 0; i < _availableRoutes.length; i++) {
        final dist = RoutingService.distanceToPolyline(point, _availableRoutes[i].points);
        if (dist < minDistance) {
          minDistance = dist;
          bestIndex = i;
        }
      }

      if (bestIndex != -1 && bestIndex != _selectedRouteIndex) {
        _selectRoute(bestIndex);
        return;
      }
    }

    // 2. Otherwise set new tapped destination
    setState(() {
      _destination = point;
      _destinationAddress = 'Resolving address…';
      _searchController.text = 'Resolving address…';
      _suggestions = [];
    });

    try {
      final addr = await RoutingService.reverseGeocode(point);
      if (mounted) {
        setState(() {
          _destinationAddress = addr;
          _searchController.text = addr;
        });
      }
    } catch (_) {
      if (mounted) {
        final fallback = 'Location (${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)})';
        setState(() {
          _destinationAddress = fallback;
          _searchController.text = fallback;
        });
      }
    }

    _calculateAndDisplayRoute();
  }

  void _onSearchChanged(String query) {
    _searchDebounceTimer?.cancel();

    if (query.trim().length < 2 || !_searchFocusNode.hasFocus) {
      setState(() {
        _suggestions = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () async {
      final results = await RoutingService.fetchAutocompleteSuggestions(
        query,
        nearLocation: _currentLocation ?? _startLocation,
      );

      if (!mounted || !_searchFocusNode.hasFocus) return;
      setState(() {
        _suggestions = results;
        _isSearching = false;
      });
    });
  }

  void _onSelectSuggestion(PlaceSuggestion suggestion) {
    _searchDebounceTimer?.cancel();
    _searchFocusNode.unfocus();
    setState(() {
      _destination = LatLng(suggestion.latitude, suggestion.longitude);
      _destinationAddress = suggestion.fullAddress;
      _searchController.text = suggestion.title;
      _suggestions = [];
      _isSearching = false;
    });

    _calculateAndDisplayRoute();
  }

  Future<void> _pickDestinationOnMap() async {
    _searchDebounceTimer?.cancel();
    _searchFocusNode.unfocus();
    setState(() {
      _suggestions = [];
      _isSearching = false;
    });

    final result = await Navigator.push<LocationPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPosition: _destination ?? _currentLocation ?? _startLocation,
          title: 'Pick Drop Location',
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        _destination = LatLng(result.latitude, result.longitude);
        _destinationAddress = result.address;
        _searchController.text = result.address;
        _suggestions = [];
        _isSearching = false;
      });

      _calculateAndDisplayRoute();
    }
  }

  Future<void> _handleSearchSubmit(String query) async {
    _searchDebounceTimer?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _searchFocusNode.unfocus();

    setState(() {
      _isSearching = true;
      _suggestions = [];
    });

    final place = await RoutingService.geocodeQuery(
      trimmed,
      nearLocation: _currentLocation ?? _startLocation,
    );

    if (!mounted) return;
    setState(() => _isSearching = false);

    if (place != null) {
      _onSelectSuggestion(place);
    } else {
      _showSnackBar(
        'Could not locate "$trimmed". Please try a landmark name or tap the map icon to pick.',
        Colors.orange,
      );
    }
  }

  // ─── 3. ROUTE CALCULATION & CAMERA FRAMING ─────────────────────────────────
  Future<void> _calculateAndDisplayRoute() async {
    final start = _currentLocation ?? _startLocation;
    final dest = _destination;
    if (start == null || dest == null) return;

    setState(() {
      _isCalculatingRoute = true;
      _availableRoutes = [];
      _selectedRouteIndex = 0;
    });

    final routes = await RoutingService.fetchRoadRoutes(start, dest);

    if (!mounted) return;
    setState(() {
      _isCalculatingRoute = false;
      _availableRoutes = routes;
      if (routes.isNotEmpty) {
        _selectedRouteIndex = 0;
        _routeInfo = routes.first;
        _routePoints = routes.first.points;
        _remainingDistanceMeters = routes.first.distanceMeters;
        _remainingDurationText = routes.first.formattedDuration;
      }
    });

    // Auto-fit camera to enclose all alternative routes with comfortable padding
    if (_routePoints.isNotEmpty) {
      final allPoints = <LatLng>[];
      for (final r in _availableRoutes) {
        allPoints.addAll(r.points);
      }
      _fitRouteCamera(start, dest, allPoints.isNotEmpty ? allPoints : _routePoints);
    }
  }

  void _selectRoute(int index) {
    if (index < 0 || index >= _availableRoutes.length || _isActive) return;
    setState(() {
      _selectedRouteIndex = index;
      _routeInfo = _availableRoutes[index];
      _routePoints = _availableRoutes[index].points;
      _remainingDistanceMeters = _availableRoutes[index].distanceMeters;
      _remainingDurationText = _availableRoutes[index].formattedDuration;
    });
  }

  void _fitRouteCamera(LatLng start, LatLng dest, List<LatLng> points) {
    if (points.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final bounds = LatLngBounds.fromPoints([start, dest, ...points]);
        if ((bounds.northEast.latitude - bounds.southWest.latitude).abs() < 0.0001 &&
            (bounds.northEast.longitude - bounds.southWest.longitude).abs() < 0.0001) {
          _mapController.move(start, 16);
        } else {
          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: bounds,
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 90),
            ),
          );
        }
      } catch (_) {
        try {
          _mapController.move(start, 15);
        } catch (_) {}
      }
    });
  }

  Future<void> _recalculateRoute() async {
    final start = _currentLocation ??
        (_lastPosition != null
            ? LatLng(_lastPosition!.latitude, _lastPosition!.longitude)
            : _startLocation);
    final dest = _destination;
    if (start == null || dest == null) return;

    if (mounted) {
      _showSnackBar('Recalculating route from current location…', const Color(0xFF1D4ED8));
    }
    setState(() => _isCalculatingRoute = true);

    final route = await RoutingService.fetchRoadRoute(start, dest);

    if (!mounted) return;
    setState(() {
      _isCalculatingRoute = false;
      if (route != null) {
        _routeInfo = route;
        _routePoints = route.points;
        _remainingDistanceMeters = route.distanceMeters;
        _remainingDurationText = route.formattedDuration;
        _consecutiveDeviationCount = 0;
        _isDeviationActive = false;
      }
    });

    if (route != null) {
      _updateFirestoreDeviationStatus(false);
      _showSnackBar('Route updated successfully!', Colors.green);
      if (_routePoints.isNotEmpty) {
        _fitRouteCamera(start, dest, _routePoints);
      }
    } else {
      _showSnackBar('Could not recalculate route. Please check connection.', Colors.red);
    }
  }

  // ─── 4. REAL-TIME MOVEMENT TRACKING & FOREGROUND SERVICE ───────────────────
  Future<void> _startForegroundService() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'companion_tracking',
        channelName: 'SafetyGuardian Companion Mode',
        channelDescription: 'Active trip monitoring & safety companion',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );

    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      notificationTitle: 'SafetyGuardian — Companion Mode Active',
      notificationText: 'Tracking journey to $_destinationAddress',
    );
  }

  Future<void> _stopForegroundService() async {
    // Shared with distress detection: don't switch that off.
    await DistressMonitor.instance.releaseForegroundService();
  }

  Future<void> _startCompanionMode() async {
    if (_destination == null || _routePoints.isEmpty) {
      _showSnackBar('Please search or select a destination first', Colors.orange);
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnackBar('You must be logged in to start Companion Mode', Colors.red);
      return;
    }

    // Check trusted contacts before departure to ensure safety alerts can reach someone
    await _sosService.loadContacts();
    final contacts = _sosService.trustedContacts;
    final validContacts = contacts.where((c) {
      final p = c['phone'];
      if (p == null) return false;
      return p.replaceAll(RegExp(r'[^\d+]'), '').isNotEmpty;
    }).toList();

    if (validContacts.isEmpty) {
      final proceed = await _showNoContactsWarningDialog();
      if (proceed != true) return;
    }

    // Request permissions
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _showSnackBar('Location permission required for trip tracking', Colors.red);
      return;
    }

    // Explicitly check/request SMS and Phone permissions for background dispatch
    try {
      await Permission.sms.request();
      await Permission.phone.request();
    } catch (_) {}

    // Stop pre-start live location stream as active trip tracking begins
    _preStartSubscription?.cancel();
    _preStartSubscription = null;

    // Start Foreground Service
    await _startForegroundService();

    final now = DateTime.now();
    _sessionId = '${user.uid}_${now.millisecondsSinceEpoch}';

    setState(() {
      _isActive = true;
      _startedAt = now;
      _updatesPushed = 0;
      _consecutiveDeviationCount = 0;
      _isDeviationActive = false;
      _lastDeviationAlertTime = null;
      _autoFollowUser = true;
    });

    // 1. Initial Location Sharing SMS to trusted contacts (dispatched immediately)
    try {
      await _sendJourneyStartSms();
    } catch (e) {
      debugPrint('Error sending initial journey SMS: $e');
    }

    // 2. Initial Firestore write (safely isolated)
    try {
      await _writeSessionStart();
    } catch (e) {
      debugPrint('Firestore write error: $e');
    }

    // 3. Continuous GPS stream
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // Battery-conscious: updates only every 5m movement
      ),
    ).listen(_handleLocationUpdate);

    // 4. Periodic Firestore push timer (every 15s)
    _firestoreSyncTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _pushLiveLocationToFirestore(),
    );

    _showSnackBar('Companion Mode Started! Trusted contacts notified.', Colors.green);
  }

  void _handleLocationUpdate(Position pos) {
    if (!mounted || !_isActive) return;

    final newLatLng = LatLng(pos.latitude, pos.longitude);

    // Calculate heading/bearing for directional arrow navigation
    double heading = pos.heading;
    if (heading == 0.0 && _currentLocation != null) {
      final distMoved = const Distance().as(LengthUnit.Meter, _currentLocation!, newLatLng);
      if (distMoved > 2.0) {
        heading = Geolocator.bearingBetween(
          _currentLocation!.latitude,
          _currentLocation!.longitude,
          newLatLng.latitude,
          newLatLng.longitude,
        );
      }
    }
    if (heading != 0.0) {
      _userHeading = (heading + 360) % 360;
    }

    _lastPosition = pos;

    setState(() {
      _currentLocation = newLatLng;
    });

    if (_autoFollowUser) {
      _mapController.move(newLatLng, _mapController.camera.zoom);
    }

    // Calculate remaining distance to destination
    if (_destination != null) {
      final remainingMeters = const Distance().as(
        LengthUnit.Meter,
        newLatLng,
        _destination!,
      );

      final estSeconds = remainingMeters / (pos.speed > 1.5 ? pos.speed : 8.33);
      final mins = (estSeconds / 60).round();
      final durationText = mins < 60 ? '$mins mins' : '${mins ~/ 60}h ${mins % 60}m';

      setState(() {
        _remainingDistanceMeters = remainingMeters;
        _remainingDurationText = durationText;
      });

      // Update background foreground notification with remaining distance & ETA
      final distFormatted = remainingMeters < 1000
          ? '${remainingMeters.toStringAsFixed(0)} m'
          : '${(remainingMeters / 1000).toStringAsFixed(1)} km';
      FlutterForegroundTask.updateService(
        notificationTitle: 'SafetyGuardian — Tracking Active',
        notificationText: '$distFormatted away • ETA $durationText',
      );

      // ─── 9. ARRIVAL DETECTION (Accuracy guarded to avoid false trigger) ──────
      if (remainingMeters <= arrivalRadiusMeters && pos.accuracy <= 40.0) {
        _handleArrivalDetected();
        return;
      }
    }

    // ─── 5. ROUTE DEVIATION DETECTION ────────────────────────────────────────
    _checkRouteDeviation(pos, newLatLng);
  }

  // ─── 5. ROBUST ROUTE DEVIATION DETECTION ───────────────────────────────────
  void _checkRouteDeviation(Position pos, LatLng currentPoint) {
    if (_routePoints.isEmpty || !_isActive) return;

    // Skip deviation checks if route is straight-line fallback to avoid false alarms
    if (_routeInfo?.isRoadRoute == false) {
      debugPrint('Skipping deviation check: route is straight-line fallback');
      return;
    }

    // Ignore reading if GPS accuracy is too poor to prevent false alarms
    if (pos.accuracy > minGpsAccuracyMeters) {
      debugPrint('Skipping deviation check: GPS accuracy ${pos.accuracy}m > $minGpsAccuracyMeters');
      return;
    }

    // Filter stationary GPS drift (e.g. stopped at traffic light or indoors)
    if (pos.speed < 0.3 && _consecutiveDeviationCount == 0) {
      debugPrint('Skipping deviation check: stationary drift (${pos.speed.toStringAsFixed(2)} m/s)');
      return;
    }

    final distanceToRoute = RoutingService.distanceToPolyline(
      currentPoint,
      _routePoints,
    );

    debugPrint('Distance to planned route: ${distanceToRoute.toStringAsFixed(1)} m');

    if (distanceToRoute > deviationThresholdMeters) {
      _consecutiveDeviationCount++;
      debugPrint('Consecutive deviations: $_consecutiveDeviationCount / $deviationPersistenceCount');

      if (_consecutiveDeviationCount >= deviationPersistenceCount) {
        final now = DateTime.now();
        final inCooldown = _lastDeviationAlertTime != null &&
            now.difference(_lastDeviationAlertTime!) < deviationAlertCooldown;

        if (!_isDeviationActive || !inCooldown) {
          _triggerRouteDeviationAlert(currentPoint);
        }
      }
    } else {
      // User is safely on route
      if (_consecutiveDeviationCount > 0) {
        setState(() {
          _consecutiveDeviationCount = 0;
        });
      }

      if (_isDeviationActive) {
        setState(() {
          _isDeviationActive = false;
        });
        _updateFirestoreDeviationStatus(false);
      }
    }
  }

  // ─── 6. ROUTE DEVIATION ALERT & TRUSTED CONTACTS SMS ───────────────────────
  Future<void> _triggerRouteDeviationAlert(LatLng point) async {
    _lastDeviationAlertTime = DateTime.now();
    setState(() => _isDeviationActive = true);

    // 1. Send SMS alert to trusted contacts IMMEDIATELY
    final shortDest = _destinationAddress.split(',').take(2).join(',').trim();
    final destText = shortDest.isNotEmpty ? ' Heading to: $shortDest.' : '';
    final alertMessage =
        'SafetyGuardian ALERT: $_userName deviated from route!$destText Location: https://maps.google.com/?q=${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}';

    try {
      await _sendSmsToTrustedContacts(alertMessage);
    } catch (e) {
      debugPrint('Error sending deviation SMS: $e');
    }

    // 2. Safely record deviation in Firestore
    try {
      await _updateFirestoreDeviationStatus(true);
    } catch (e) {
      debugPrint('Error updating Firestore deviation: $e');
    }

    // 3. Display deviation warning dialog on screen
    if (mounted) {
      _showDeviationWarningDialog();
    }
  }

  void _showDeviationWarningDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning, color: Colors.red, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Route Deviation Alert',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ),
          ],
        ),
        content: const Text(
          'You appear to be significantly off your planned route. '
          'Your trusted contacts have been alerted with your location. Are you safe?',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("I'm Safe", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _recalculateRoute();
            },
            icon: const Icon(Icons.alt_route, color: Color(0xFF1D4ED8), size: 18),
            label: const Text('Reroute', style: TextStyle(color: Color(0xFF1D4ED8), fontWeight: FontWeight.bold)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pushNamed(context, '/sos', arguments: 'activate');
            },
            icon: const Icon(Icons.emergency, size: 18),
            label: const Text('Emergency SOS'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  // ─── 7. INITIAL JOURNEY START SMS ──────────────────────────────────────────
  Future<void> _sendJourneyStartSms() async {
    final start = _currentLocation ??
        _startLocation ??
        (_lastPosition != null ? LatLng(_lastPosition!.latitude, _lastPosition!.longitude) : null);
    final String locationPart;
    if (start != null) {
      locationPart = 'Live location: https://maps.google.com/?q=${start.latitude.toStringAsFixed(5)},${start.longitude.toStringAsFixed(5)}';
    } else {
      locationPart = 'Trip in progress.';
    }
    final shortDest = _destinationAddress.split(',').take(2).join(',').trim();
    final dest = shortDest.isNotEmpty ? shortDest : 'destination';
    final message =
        'SafetyGuardian: $_userName has started Companion Mode to $dest. $locationPart';

    await _sendSmsToTrustedContacts(message);
  }

  // ─── 9. DESTINATION ARRIVAL HANDLING ───────────────────────────────────────
  Future<void> _handleArrivalDetected() async {
    final tripDuration = _elapsedTimeString;
    final totalDistance = _routeInfo?.formattedDistance ?? '';

    // 1. Notify trusted contacts of safe arrival with final location link
    final endLoc = _currentLocation ??
        (_lastPosition != null
            ? LatLng(_lastPosition!.latitude, _lastPosition!.longitude)
            : _destination);
    final locPart = endLoc != null
        ? ' Location: https://maps.google.com/?q=${endLoc.latitude.toStringAsFixed(5)},${endLoc.longitude.toStringAsFixed(5)}'
        : '';
    final shortDest = _destinationAddress.split(',').take(2).join(',').trim();
    final destText = shortDest.isNotEmpty ? shortDest : 'destination';
    final message =
        'SafetyGuardian: $_userName has arrived safely at $destText.$locPart';
    try {
      await _sendSmsToTrustedContacts(message);
    } catch (e) {
      debugPrint('Error sending arrival SMS: $e');
    }

    // 2. Stop companion mode tracking cleanly
    await _stopCompanionMode(completed: true);

    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 30),
              SizedBox(width: 10),
              Text('You Have Arrived!'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You have successfully reached your destination: $_destinationAddress.',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade100),
                ),
                child: Column(
                  children: [
                    if (tripDuration.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Trip Duration:', style: TextStyle(fontSize: 13, color: Colors.black54)),
                          Text(tripDuration, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    if (totalDistance.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Distance:', style: TextStyle(fontSize: 13, color: Colors.black54)),
                          Text(totalDistance, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('SMS Status:', style: TextStyle(fontSize: 13, color: Colors.black54)),
                        Text('Arrival SMS Sent', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.green)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1D4ED8),
                foregroundColor: Colors.white,
              ),
              child: const Text('Awesome'),
            ),
          ],
        ),
      );
    }
  }

  Future<bool?> _showNoContactsWarningDialog() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.contact_phone_outlined, color: Colors.orange, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'No Trusted Contacts',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ),
          ],
        ),
        content: const Text(
          'You have not added any trusted contacts yet. In an emergency or route deviation, no one will receive automated SMS alerts.\n\nWould you like to start anyway?',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel & Add Contacts'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('Start Anyway'),
          ),
        ],
      ),
    );
  }

  // ─── SMS HELPER (REUSING SosService) ───────────────────────────────────────
  Future<void> _sendSmsToTrustedContacts(String message) async {
    try {
      await _sosService.loadContacts();
      final contacts = _sosService.trustedContacts;

      final seen = <String>{};
      final validContacts = contacts.where((c) {
        final p = c['phone'];
        if (p == null) return false;
        final clean = p.replaceAll(RegExp(r'[^\d+]'), '');
        return clean.isNotEmpty && seen.add(clean);
      }).toList();

      if (validContacts.isEmpty) {
        debugPrint('⚠️ No trusted contacts with phone numbers found.');
        if (mounted) {
          _showSnackBar(
            'No contact numbers found. Please add numbers in Manage Contacts',
            Colors.orange,
          );
        }
        return;
      }

      debugPrint('📨 Dispatching trip SMS to ALL ${validContacts.length} trusted contact(s)...');
      int sentCount = 0;
      for (final contact in validContacts) {
        final phone = contact['phone']!;
        final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
        try {
          final sent = await _sosService.sendSms(cleanPhone, message);
          if (!sent) throw Exception('not sent');
          sentCount++;
          debugPrint('✅ Sent trip SMS ($sentCount/${validContacts.length}) to ${contact['name']} ($cleanPhone)');
        } catch (e) {
          debugPrint('❌ Failed to send SMS to $cleanPhone: $e');
        }

        // Delay between cellular dispatches to allow Android modem
        // radio buffer (RIL) to transmit each SMS without collision
        if (validContacts.length > 1) {
          await Future.delayed(const Duration(milliseconds: 1000));
        }
      }

      if (sentCount > 0 && mounted) {
        _showSnackBar('Sent trip SMS to all $sentCount contact(s)', Colors.green);
      }
    } catch (e) {
      debugPrint('Error sending SMS to trusted contacts: $e');
      if (mounted) {
        _showSnackBar('Error sending SMS: $e', Colors.red);
      }
    }
  }

  // ─── 8. FIRESTORE LIVE TRACKING ────────────────────────────────────────────
  Future<void> _writeSessionStart() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || _destination == null || _sessionId == null) return;

      final start = _startLocation ?? _currentLocation;
      final sessionData = {
        'sessionId': _sessionId,
        'userId': user.uid,
        'userName': _userName,
        'userEmail': user.email,
        'startLocation': {
          'lat': start?.latitude ?? 0.0,
          'lng': start?.longitude ?? 0.0,
          'address': _startAddress,
        },
        'destination': {
          'lat': _destination!.latitude,
          'lng': _destination!.longitude,
          'address': _destinationAddress,
        },
        'currentLocation': {
          'lat': start?.latitude ?? 0.0,
          'lng': start?.longitude ?? 0.0,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        'totalDistanceMeters': _routeInfo?.distanceMeters ?? 0.0,
        'remainingDistanceMeters': _remainingDistanceMeters,
        'status': 'active',
        'deviationDetected': false,
        'startedAt': FieldValue.serverTimestamp(),
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      };

      // Save unique session doc
      await FirebaseFirestore.instance
          .collection('companion_sessions')
          .doc(_sessionId)
          .set(sessionData);

      // Also update user's latest session pointer for quick lookup by police/guardians
      await FirebaseFirestore.instance
          .collection('companion_sessions')
          .doc(user.uid)
          .set(sessionData, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Firestore session start error: $e');
    }
  }

  Future<void> _pushLiveLocationToFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _lastPosition == null || _sessionId == null) return;

    final updateData = {
      'currentLocation': {
        'lat': _lastPosition!.latitude,
        'lng': _lastPosition!.longitude,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      'remainingDistanceMeters': _remainingDistanceMeters,
      'lastUpdatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await FirebaseFirestore.instance
          .collection('companion_sessions')
          .doc(_sessionId)
          .set(updateData, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('companion_sessions')
          .doc(user.uid)
          .set(updateData, SetOptions(merge: true));

      if (mounted) {
        setState(() => _updatesPushed++);
      }
    } catch (e) {
      debugPrint('Firestore push error: $e');
    }
  }

  Future<void> _updateFirestoreDeviationStatus(bool deviated) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || _sessionId == null) return;

      final data = {
        'deviationDetected': deviated,
        if (deviated) 'deviationAt': FieldValue.serverTimestamp(),
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('companion_sessions')
          .doc(_sessionId)
          .set(data, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('companion_sessions')
          .doc(user.uid)
          .set(data, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Firestore deviation update error: $e');
    }
  }

  // ─── STOP TRACKING & CLEANUP ───────────────────────────────────────────────
  Future<void> _stopCompanionMode({bool completed = false}) async {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _firestoreSyncTimer?.cancel();
    _firestoreSyncTimer = null;

    try {
      await _stopForegroundService();
    } catch (_) {}

    final user = FirebaseAuth.instance.currentUser;
    if (user != null && _sessionId != null) {
      try {
        final endData = {
          'status': completed ? 'completed' : 'cancelled',
          'active': false,
          'endedAt': FieldValue.serverTimestamp(),
        };

        await FirebaseFirestore.instance
            .collection('companion_sessions')
            .doc(_sessionId)
            .set(endData, SetOptions(merge: true));

        await FirebaseFirestore.instance
            .collection('companion_sessions')
            .doc(user.uid)
            .set(endData, SetOptions(merge: true));
      } catch (e) {
        debugPrint('Firestore session stop write error: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _isActive = false;
      _isDeviationActive = false;
      _consecutiveDeviationCount = 0;
    });

    if (!completed) {
      _showSnackBar('Companion Mode Stopped', Colors.orange);
      try {
        LatLng? endLoc = _currentLocation ??
            (_lastPosition != null
                ? LatLng(_lastPosition!.latitude, _lastPosition!.longitude)
                : _startLocation);

        if (endLoc == null) {
          try {
            final last = await Geolocator.getLastKnownPosition();
            if (last != null) {
              endLoc = LatLng(last.latitude, last.longitude);
            }
          } catch (_) {}
        }

        final locPart = endLoc != null
            ? ' Location: https://maps.google.com/?q=${endLoc.latitude.toStringAsFixed(5)},${endLoc.longitude.toStringAsFixed(5)}'
            : '';

        await _sendSmsToTrustedContacts(
          'SafetyGuardian: $_userName has ended the trip.$locPart',
        );
      } catch (e) {
        debugPrint('Error sending trip end SMS: $e');
      }
    }
  }

  // ─── DIALOGS & ALERTS ──────────────────────────────────────────────────────
  void _showGpsDisabledDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('GPS Service Disabled'),
        content: const Text('Please enable location services on your device to use Companion Mode.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Geolocator.openLocationSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _showPermissionDeniedForeverDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Location Permission Needed'),
        content: const Text('Location permission is permanently denied. Please allow location in App Settings.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Geolocator.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  // ─── MAP LAYERS ────────────────────────────────────────────────────────────
  List<Marker> _buildMarkers() {
    final markers = <Marker>[];

    // 1. Current user location marker
    if (_currentLocation != null) {
      final isMoving = _lastPosition != null && _lastPosition!.speed > 1.2;
      markers.add(
        Marker(
          point: _currentLocation!,
          width: 44,
          height: 44,
          child: isMoving
              ? Transform.rotate(
                  angle: (_userHeading * math.pi / 180),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isDeviationActive ? Colors.red : const Color(0xFF1D4ED8),
                      border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 5)],
                    ),
                    child: const Icon(
                      Icons.navigation,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                )
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: (_isDeviationActive ? Colors.red : const Color(0xFF1D4ED8))
                            .withValues(alpha: 0.25),
                      ),
                    ),
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isDeviationActive ? Colors.red : const Color(0xFF1D4ED8),
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                      ),
                    ),
                  ],
                ),
        ),
      );
    }

    // 2. Start location marker (if not tracking yet)
    if (!_isActive && _startLocation != null && _startLocation != _currentLocation) {
      markers.add(
        Marker(
          point: _startLocation!,
          width: 32,
          height: 32,
          child: const Icon(Icons.circle, color: Colors.green, size: 24),
        ),
      );
    }

    // 3. Destination marker
    if (_destination != null) {
      markers.add(
        Marker(
          point: _destination!,
          width: 44,
          height: 44,
          child: const Icon(Icons.location_on, color: Colors.red, size: 42),
        ),
      );
    }

    return markers;
  }

  List<Polyline> _buildPolylines() {
    if (_routePoints.isEmpty && _availableRoutes.isEmpty) return [];

    final polylines = <Polyline>[];

    // In preview mode, render unselected alternative routes in muted grey (Google Maps style)
    if (!_isActive && _availableRoutes.length > 1) {
      for (int i = 0; i < _availableRoutes.length; i++) {
        if (i == _selectedRouteIndex) continue;
        final altRoute = _availableRoutes[i];
        // Outer subtle outline
        polylines.add(
          Polyline(
            points: altRoute.points,
            color: Colors.blueGrey.shade200.withValues(alpha: 0.6),
            strokeWidth: 7,
          ),
        );
        // Inner grey polyline
        polylines.add(
          Polyline(
            points: altRoute.points,
            color: Colors.blueGrey.shade400,
            strokeWidth: 4,
          ),
        );
      }
    }

    // Now render the active/selected route on top
    if (_routePoints.isNotEmpty) {
      // Outer shadow/border line
      polylines.add(
        Polyline(
          points: _routePoints,
          color: (_isDeviationActive ? Colors.red.shade900 : const Color(0xFF1D4ED8))
              .withValues(alpha: 0.5),
          strokeWidth: 8,
        ),
      );
      // Inner crisp road polyline
      polylines.add(
        Polyline(
          points: _routePoints,
          color: _isDeviationActive ? Colors.red : const Color(0xFF1D4ED8),
          strokeWidth: 5,
        ),
      );
    }

    return polylines;
  }

  // ─── UI BUILD ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isActive,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isActive) {
          _showExitConfirmationDialog();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: const Text('Companion Mode'),
          backgroundColor: _isDeviationActive
              ? Colors.red
              : (_isActive ? Colors.green.shade700 : const Color(0xFF1D4ED8)),
          foregroundColor: Colors.white,
          actions: [
            if (_isActive)
              IconButton(
                tooltip: 'Emergency SOS',
                icon: const Icon(Icons.emergency, color: Colors.white),
                onPressed: () =>
                    Navigator.pushNamed(context, '/sos', arguments: 'activate'),
              ),
          ],
        ),
        body: Stack(
          children: [
            // ─── FULL-SCREEN MAP ───────────────────────────────────────────
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _startLocation ?? const LatLng(33.7710, 72.3596),
                initialZoom: 15,
                onTap: (tapPosition, point) => _handleMapTap(point),
                onPositionChanged: (camera, hasGesture) {
                  if (hasGesture && _autoFollowUser) {
                    setState(() => _autoFollowUser = false);
                  }
                },
              ),
              children: [
                // OpenStreetMap tiles. OSM blocks apps that identify as
                // 'com.example...', so a real app id is sent instead.
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'pk.safetyguardian.app',
                  maxNativeZoom: 19,
                ),
                PolylineLayer(polylines: _buildPolylines()),
                MarkerLayer(markers: _buildMarkers()),
              ],
            ),

            // ─── RE-CENTER BUTTON ──────────────────────────────────────────
            Positioned(
              right: 16,
              bottom: _isActive ? 220 : 250,
              child: FloatingActionButton.small(
                heroTag: 'recenter_fab',
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF1D4ED8),
                onPressed: () {
                  final target = _currentLocation ?? _startLocation;
                  if (target != null) {
                    setState(() => _autoFollowUser = true);
                    _mapController.move(target, 16);
                  }
                },
                child: Icon(_autoFollowUser ? Icons.my_location : Icons.location_searching),
              ),
            ),

            // ─── TOP ROUTE / SEARCH / STATUS OVERLAY ───────────────────────
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_isActive) ...[
                    _buildRouteHeaderCard(),
                    if (_suggestions.isNotEmpty && _searchFocusNode.hasFocus)
                      _buildSuggestionsDropdown(),
                  ] else ...[
                    _buildActiveStatusBanner(),
                  ],
                ],
              ),
            ),

            // ─── BOTTOM CONTROLS & TRIP METRICS CARD ───────────────────────
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomTripCard(),
            ),
          ],
        ),
      ),
    );
  }

  // ─── WIDGET: UNIFIED ROUTE HEADER (START + DESTINATION) ────────────────────
  Widget _buildRouteHeaderCard() {
    return Card(
      elevation: 6,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ─── 1. START LOCATION ROW ───
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.trip_origin, color: Colors.green.shade600, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Start Location',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey.shade600,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.green.shade100,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Auto GPS',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.green.shade800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _startAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_isActive)
                  IconButton(
                    tooltip: 'Refresh Current Location',
                    icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF1D4ED8)),
                    onPressed: _initStartLocation,
                  ),
              ],
            ),

            // Route connector line
            Padding(
              padding: const EdgeInsets.only(left: 13, top: 3, bottom: 3),
              child: Row(
                children: [
                  Container(
                    width: 2,
                    height: 14,
                    color: Colors.grey.shade300,
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Divider(height: 1, color: Colors.grey.shade200)),
                ],
              ),
            ),

            // ─── 2. DESTINATION / END LOCATION ROW ───
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.location_on, color: Colors.red, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    enabled: !_isActive,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _handleSearchSubmit,
                    onChanged: _onSearchChanged,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      hintText: 'Enter destination or place name…',
                      hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                if (_isSearching)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_searchController.text.isNotEmpty && !_isActive)
                  IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _suggestions = [];
                        _destination = null;
                        _destinationAddress = '';
                        _routePoints = [];
                        _routeInfo = null;
                        _availableRoutes = [];
                        _selectedRouteIndex = 0;
                      });
                    },
                  ),
                if (!_isActive)
                  IconButton(
                    tooltip: 'Pick on Map',
                    icon: const Icon(Iconsax.map, color: Color(0xFF1D4ED8), size: 20),
                    onPressed: _pickDestinationOnMap,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── WIDGET: AUTOCOMPLETE DROPDOWN ─────────────────────────────────────────
  Widget _buildSuggestionsDropdown() {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxHeight: 250),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _suggestions.length,
        separatorBuilder: (context, index) => Divider(height: 1, color: Colors.grey.shade200),
        itemBuilder: (context, index) {
          final s = _suggestions[index];
          final distStr = s.formattedDistanceFrom(_currentLocation ?? _startLocation);

          return ListTile(
            dense: true,
            leading: const Icon(Icons.location_on_outlined, color: Color(0xFF1D4ED8)),
            title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            subtitle: s.subtitle.isNotEmpty
                ? Text(
                    s.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  )
                : null,
            trailing: distStr.isNotEmpty
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.shade100),
                    ),
                    child: Text(
                      distStr,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF1D4ED8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : null,
            onTap: () => _onSelectSuggestion(s),
          );
        },
      ),
    );
  }

  // ─── WIDGET: ACTIVE TRIP STATUS BANNER ─────────────────────────────────────
  Widget _buildActiveStatusBanner() {
    if (_isDeviationActive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.red.shade600,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [BoxShadow(color: Colors.redAccent, blurRadius: 8)],
        ),
        child: Row(
          children: [
            const Icon(Icons.warning, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'ROUTE DEVIATION DETECTED!',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.red.shade700,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _recalculateRoute,
              child: const Text('Reroute', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.green.shade600,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shield_outlined, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Trip Monitoring Active • Destination: $_destinationAddress',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ─── WIDGET: BOTTOM TRIP CARD ──────────────────────────────────────────────
  Widget _buildBottomTripCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 15, offset: Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),

            if (_isCalculatingRoute)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('Calculating optimal road route…'),
                    ],
                  ),
                ),
              )
            else if (_destination == null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  children: [
                    const Icon(Iconsax.info_circle, color: Color(0xFF1D4ED8), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Enter Destination Above',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          Text(
                            'Start location is auto-detected. Type an end destination or pick on map.',
                            style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Iconsax.map, size: 18),
                      label: const Text('Pick on Map'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1D4ED8),
                        side: const BorderSide(color: Color(0xFF1D4ED8)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _pickDestinationOnMap,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('Search & Route'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1D4ED8),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () {
                        if (_searchController.text.trim().isNotEmpty) {
                          _handleSearchSubmit(_searchController.text);
                        } else {
                          _searchFocusNode.requestFocus();
                          _showSnackBar('Please type a destination name above', Colors.blue);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Destination details
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_on, color: Colors.red, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Destination', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        Text(
                          _destinationAddress,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!_isActive && _availableRoutes.length > 1) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.alt_route, size: 16, color: Color(0xFF1D4ED8)),
                    const SizedBox(width: 6),
                    Text(
                      'AVAILABLE ROUTES (${_availableRoutes.length})',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1D4ED8),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 58,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _availableRoutes.length,
                    itemBuilder: (context, i) {
                      final r = _availableRoutes[i];
                      final isSelected = i == _selectedRouteIndex;
                      final isFastest = i == 0;
                      final title = isFastest ? 'Route 1 (Fastest)' : 'Route ${i + 1}';
                      final subText = r.summary.isNotEmpty
                          ? '${r.formattedDuration} • via ${r.summary}'
                          : '${r.formattedDuration} • ${r.formattedDistance}';

                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: () => _selectRoute(i),
                          borderRadius: BorderRadius.circular(14),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF1D4ED8).withValues(alpha: 0.1)
                                  : Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF1D4ED8)
                                    : Colors.grey.shade300,
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                                      size: 14,
                                      color: isSelected ? const Color(0xFF1D4ED8) : Colors.grey,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      title,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                        color: isSelected ? const Color(0xFF1D4ED8) : Colors.black87,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  subText,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isSelected ? const Color(0xFF1D4ED8) : Colors.grey.shade600,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 14),

              // Metrics Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMetricTile(
                    'Distance',
                    _isActive
                        ? (_remainingDistanceMeters < 1000
                            ? '${_remainingDistanceMeters.toStringAsFixed(0)} m'
                            : '${(_remainingDistanceMeters / 1000).toStringAsFixed(1)} km')
                        : (_routeInfo?.formattedDistance ?? '—'),
                    Iconsax.routing,
                  ),
                  _buildMetricTile(
                    _isActive ? 'ETA (Elapsed)' : 'ETA',
                    _isActive
                        ? '$_remainingDurationText ($_elapsedTimeString)'
                        : (_routeInfo?.formattedDuration ?? '—'),
                    Iconsax.clock,
                  ),
                  _buildMetricTile(
                    'Status',
                    _isActive ? (_isDeviationActive ? 'Off Route' : 'Safe') : 'Ready',
                    Iconsax.shield_tick,
                    color: _isActive
                        ? (_isDeviationActive ? Colors.red : Colors.green)
                        : const Color(0xFF1D4ED8),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Action Buttons
              if (!_isActive)
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    icon: const Icon(Iconsax.radar_2),
                    label: const Text(
                      'Start Companion Mode',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1D4ED8),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 4,
                    ),
                    onPressed: _startCompanionMode,
                  ),
                )
              else ...[
                if (_isDeviationActive) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _recalculateRoute,
                      icon: const Icon(Icons.alt_route, size: 18),
                      label: const Text(
                        'Recalculate Route from Current Location',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber.shade800,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.flag_outlined, color: Colors.green),
                          label: const Text(
                            "I've Arrived",
                            style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.green),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: () => _handleArrivalDetected(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.stop_circle),
                          label: const Text(
                            'End Trip',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: () => _stopCompanionMode(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricTile(String label, String value, IconData icon, {Color? color}) {
    final themeColor = color ?? const Color(0xFF1D4ED8);
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: themeColor),
        ),
      ],
    );
  }

  void _showExitConfirmationDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trip Active'),
        content: const Text('Companion Mode is currently monitoring your trip. Are you sure you want to stop tracking and exit?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Stay')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _stopCompanionMode();
              Navigator.pop(context);
            },
            child: const Text('Stop & Exit'),
          ),
        ],
      ),
    );
  }
}
