import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';

class PlaceSuggestion {
  final String title;
  final String subtitle;
  final double latitude;
  final double longitude;

  PlaceSuggestion({
    required this.title,
    required this.subtitle,
    required this.latitude,
    required this.longitude,
  });

  String get fullAddress => subtitle.isNotEmpty ? '$title, $subtitle' : title;

  String formattedDistanceFrom(LatLng? origin) {
    if (origin == null) return '';
    final d = const Distance().as(
      LengthUnit.Meter,
      origin,
      LatLng(latitude, longitude),
    );
    if (d < 1000) return '${d.toStringAsFixed(0)} m away';
    return '${(d / 1000).toStringAsFixed(1)} km away';
  }
}

class RouteInfo {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final bool isRoadRoute;
  final String summary;

  RouteInfo({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.isRoadRoute = true,
    this.summary = '',
  });

  String get formattedDistance {
    if (distanceMeters < 1000) {
      return '${distanceMeters.toStringAsFixed(0)} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }

  String get formattedDuration {
    final minutes = (durationSeconds / 60).round();
    if (minutes < 60) {
      return '$minutes min${minutes == 1 ? '' : 's'}';
    }
    final hours = minutes ~/ 60;
    final remMinutes = minutes % 60;
    if (remMinutes == 0) {
      return '$hours hr${hours == 1 ? '' : 's'}';
    }
    return '$hours hr${hours == 1 ? '' : 's'} $remMinutes min${remMinutes == 1 ? '' : 's'}';
  }

  String get etaTimestamp {
    final arrivalTime = DateTime.now().add(
      Duration(seconds: durationSeconds.round()),
    );
    final hour = arrivalTime.hour > 12
        ? arrivalTime.hour - 12
        : (arrivalTime.hour == 0 ? 12 : arrivalTime.hour);
    final minute = arrivalTime.minute.toString().padLeft(2, '0');
    final period = arrivalTime.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }
}

class RoutingService {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: {'User-Agent': 'SafetyGuardian-App/1.0 (flutter; safety-app)'},
    ),
  );

  /// Fast place search and autocomplete suggestions using Nominatim (with English names)
  /// and device native geocoding as fallback.
  static Future<List<PlaceSuggestion>> fetchAutocompleteSuggestions(
    String query, {
    LatLng? nearLocation,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) return [];

    // 1. Try Nominatim OpenStreetMap Search with English formatting
    try {
      String url =
          'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(trimmed)}&format=json&addressdetails=1&limit=6&accept-language=en';
      if (nearLocation != null) {
        // Bias search towards user's current city/coordinates
        final minLon = nearLocation.longitude - 0.5;
        final maxLon = nearLocation.longitude + 0.5;
        final minLat = nearLocation.latitude - 0.5;
        final maxLat = nearLocation.latitude + 0.5;
        url += '&viewbox=$minLon,$maxLat,$maxLon,$minLat&bounded=0';
      }

      final response = await _dio.get(url);
      if (response.statusCode == 200 && response.data is List) {
        final List<PlaceSuggestion> results = [];
        for (final item in response.data) {
          final lat = double.tryParse(item['lat']?.toString() ?? '');
          final lon = double.tryParse(item['lon']?.toString() ?? '');
          final displayName = item['display_name']?.toString() ?? '';
          if (lat != null && lon != null && displayName.isNotEmpty) {
            final split = displayName.split(',');
            final title = item['name']?.toString().isNotEmpty == true
                ? item['name'].toString()
                : split.first.trim();
            final subtitle = split.length > 1
                ? split.skip(split.first.trim() == title ? 1 : 0).take(3).join(',').trim()
                : '';

            results.add(
              PlaceSuggestion(
                title: title,
                subtitle: subtitle,
                latitude: lat,
                longitude: lon,
              ),
            );
          }
        }
        if (results.isNotEmpty) return results;
      }
    } catch (e) {
      debugPrint('Nominatim search error: $e');
    }

    // 2. Fallback to platform native geocoding package (Google Play Services on Android)
    try {
      final locations = await locationFromAddress(trimmed);
      if (locations.isNotEmpty) {
        final loc = locations.first;
        return [
          PlaceSuggestion(
            title: trimmed,
            subtitle: '${loc.latitude.toStringAsFixed(4)}, ${loc.longitude.toStringAsFixed(4)}',
            latitude: loc.latitude,
            longitude: loc.longitude,
          ),
        ];
      }
    } catch (e) {
      debugPrint('Geocoding fallback error: $e');
    }

    // 3. Fallback to Photon API
    try {
      String url = 'https://photon.komoot.io/api/?q=${Uri.encodeComponent(trimmed)}&limit=5';
      if (nearLocation != null) {
        url += '&lat=${nearLocation.latitude}&lon=${nearLocation.longitude}';
      }

      final response = await _dio.get(url);
      if (response.statusCode == 200 && response.data is Map) {
        final features = response.data['features'] as List?;
        if (features != null && features.isNotEmpty) {
          final List<PlaceSuggestion> results = [];
          for (final f in features) {
            final geom = f['geometry'];
            final props = f['properties'] as Map<String, dynamic>?;
            if (geom != null && props != null) {
              final coords = geom['coordinates'] as List?;
              if (coords != null && coords.length >= 2) {
                final lon = (coords[0] as num).toDouble();
                final lat = (coords[1] as num).toDouble();

                final name = props['name']?.toString() ??
                    props['street']?.toString() ??
                    props['city']?.toString() ??
                    'Place';

                final subParts = [
                  props['street'],
                  props['city'],
                  props['state'],
                  props['country'],
                ].where((p) => p != null && p.toString().isNotEmpty && p != name).toList();

                results.add(
                  PlaceSuggestion(
                    title: name,
                    subtitle: subParts.join(', '),
                    latitude: lat,
                    longitude: lon,
                  ),
                );
              }
            }
          }
          if (results.isNotEmpty) return results;
        }
      }
    } catch (e) {
      debugPrint('Photon autocomplete error: $e');
    }

    return [];
  }

  /// Geocodes a text query into a single best place location + formatted address.
  static Future<PlaceSuggestion?> geocodeQuery(
    String query, {
    LatLng? nearLocation,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final list = await fetchAutocompleteSuggestions(trimmed, nearLocation: nearLocation);
    if (list.isNotEmpty) {
      return list.first;
    }

    try {
      final locations = await locationFromAddress(trimmed);
      if (locations.isNotEmpty) {
        final loc = locations.first;
        return PlaceSuggestion(
          title: trimmed,
          subtitle: '${loc.latitude.toStringAsFixed(4)}, ${loc.longitude.toStringAsFixed(4)}',
          latitude: loc.latitude,
          longitude: loc.longitude,
        );
      }
    } catch (_) {}

    return null;
  }

  /// Robust reverse geocoding with multi-tier fallback:
  /// 1. OpenStreetMap Nominatim (English street/suburb/city)
  /// 2. Native device Geocoder (placemarkFromCoordinates)
  /// 3. Photon reverse geocoder
  /// 4. Friendly readable coordinates fallback
  static Future<String> reverseGeocode(LatLng pos) async {
    // 1. Try Nominatim reverse geocoder with English names
    try {
      final url =
          'https://nominatim.openstreetmap.org/reverse?lat=${pos.latitude}&lon=${pos.longitude}&format=json&addressdetails=1&accept-language=en';
      final response = await _dio.get(url);
      final data = _asMap(response.data);
      if (response.statusCode == 200 && data != null) {
        final address = data['address'] as Map?;
        final name = data['name']?.toString();
        if (address != null) {
          final road = address['road'] ?? address['street'] ?? address['pedestrian'] ?? address['highway'];
          final neighbourhood = address['neighbourhood'] ??
              address['suburb'] ??
              address['residential'] ??
              address['quarter'] ??
              address['village'] ??
              address['hamlet'];
          final city = address['city'] ?? address['town'] ?? address['county'] ?? address['state_district'];
          final state = address['state'];

          final parts = [
            if (name != null && name.isNotEmpty && name != road && name != neighbourhood) name,
            if (road != null && road.toString().isNotEmpty) road.toString(),
            if (neighbourhood != null && neighbourhood.toString().isNotEmpty && neighbourhood != road)
              neighbourhood.toString(),
            if (city != null && city.toString().isNotEmpty) city.toString(),
            if (state != null && state.toString().isNotEmpty && state != city) state.toString(),
          ].map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();

          if (parts.isNotEmpty) {
            return parts.take(3).join(', ');
          }
        }
        final displayName = data['display_name']?.toString();
        if (displayName != null && displayName.isNotEmpty) {
          return displayName.split(',').take(3).join(',').trim();
        }
      }
    } catch (e) {
      debugPrint('Nominatim reverse geocode error: $e');
    }

    // 2. Try native platform Geocoder (Google Play Services on Android)
    try {
      final placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude)
          .timeout(const Duration(seconds: 6));
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        final parts = [
          p.name,
          p.street,
          p.subLocality,
          p.locality,
          p.administrativeArea,
        ].where((s) => s != null && s.isNotEmpty).toSet().toList();
        if (parts.isNotEmpty) {
          return parts.take(3).join(', ');
        }
      }
    } catch (e) {
      debugPrint('Platform geocoder error: $e');
    }

    // 3. Photon reverse geocoder
    try {
      final url = 'https://photon.komoot.io/reverse?lat=${pos.latitude}&lon=${pos.longitude}';
      final response = await _dio.get(url);
      final photon = _asMap(response.data);
      if (response.statusCode == 200 && photon != null) {
        final features = photon['features'] as List?;
        if (features != null && features.isNotEmpty) {
          final props = features.first['properties'] as Map<String, dynamic>?;
          if (props != null) {
            final name = props['name'] ?? props['street'];
            final city = props['city'] ?? props['state'];
            final parts = [name, city].where((s) => s != null && s.toString().isNotEmpty).toList();
            if (parts.isNotEmpty) {
              return parts.join(', ');
            }
          }
        }
      }
    } catch (_) {}

    // 4. BigDataCloud (free, keyless) reverse geocoder
    try {
      final url =
          'https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=${pos.latitude}&longitude=${pos.longitude}&localityLanguage=en';
      final response = await _dio.get(url);
      final data = _asMap(response.data);
      if (response.statusCode == 200 && data != null) {
        final parts = [
          data['locality'],
          data['city'],
          data['principalSubdivision'],
        ]
            .where((s) => s != null && s.toString().trim().isNotEmpty)
            .map((s) => s.toString().trim())
            .toSet()
            .toList();
        if (parts.isNotEmpty) return parts.take(3).join(', ');
      }
    } catch (e) {
      debugPrint('BigDataCloud reverse geocode error: $e');
    }

    // 5. Clean friendly coordinates
    return 'Location (${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)})';
  }

  /// Address to show for a saved report. Old reports may have stored a
  /// placeholder ("Loading address...") or nothing; show coordinates then.
  static String displayAddress(Map<String, dynamic> report) {
    final raw = (report['address'] ?? '').toString().trim();
    final low = raw.toLowerCase();
    final placeholder = raw.isEmpty ||
        low.startsWith('loading') ||
        low.startsWith('resolving');
    if (!placeholder) return raw;
    final lat = report['latitude'];
    final lng = report['longitude'];
    if (lat is num && lng is num) {
      return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    }
    return 'Location not provided';
  }

  /// Dio returns JSON as a Map, but some servers send it as text.
  static Map<dynamic, dynamic>? _asMap(dynamic data) {
    if (data is Map) return data;
    if (data is String && data.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return decoded;
      } catch (_) {}
    }
    return null;
  }

  /// Calculates multiple driving routes (including alternatives) using OSRM with
  /// multi-server fallback and unlimited coordinate snapping.
  static Future<List<RouteInfo>> fetchRoadRoutes(
    LatLng start,
    LatLng destination,
  ) async {
    final startLon = start.longitude.toStringAsFixed(6);
    final startLat = start.latitude.toStringAsFixed(6);
    final destLon = destination.longitude.toStringAsFixed(6);
    final destLat = destination.latitude.toStringAsFixed(6);

    final serverEndpoints = [
      'https://routing.openstreetmap.de/routed-car/route/v1/driving',
      'https://router.project-osrm.org/route/v1/driving',
    ];

    for (final baseServer in serverEndpoints) {
      // 1. Try with alternatives & unlimited snapping
      final withAlt = await _queryOsrmServer(
        '$baseServer/$startLon,$startLat;$destLon,$destLat'
        '?overview=full&geometries=geojson&alternatives=true&radiuses=unlimited;unlimited&continue_straight=true',
      );
      if (withAlt.isNotEmpty) return withAlt;

      // 2. Try single route with unlimited snapping (for areas with only 1 road)
      final singleSnapping = await _queryOsrmServer(
        '$baseServer/$startLon,$startLat;$destLon,$destLat'
        '?overview=full&geometries=geojson&radiuses=unlimited;unlimited&continue_straight=true',
      );
      if (singleSnapping.isNotEmpty) return singleSnapping;

      // 3. Try standard query
      final standard = await _queryOsrmServer(
        '$baseServer/$startLon,$startLat;$destLon,$destLat'
        '?overview=full&geometries=geojson',
      );
      if (standard.isNotEmpty) return standard;
    }

    // Graceful fallback: single straight-line route (only if completely offline)
    final directDistance = const Distance().as(
      LengthUnit.Meter,
      start,
      destination,
    );
    final estDuration = directDistance / 8.33;

    return [
      RouteInfo(
        points: [start, destination],
        distanceMeters: directDistance,
        durationSeconds: estDuration,
        isRoadRoute: false,
      ),
    ];
  }

  static Future<List<RouteInfo>> _queryOsrmServer(String url) async {
    try {
      final response = await _dio.get(url);
      if (response.statusCode == 200 && response.data is Map) {
        final code = response.data['code'];
        final routes = response.data['routes'] as List?;
        if (code == 'Ok' && routes != null && routes.isNotEmpty) {
          final List<RouteInfo> parsedRoutes = [];
          for (int i = 0; i < routes.length; i++) {
            final r = routes[i];
            final distance = (r['distance'] as num?)?.toDouble() ?? 0.0;
            final duration = (r['duration'] as num?)?.toDouble() ?? 0.0;
            final geometry = r['geometry'];
            final coordinates = geometry?['coordinates'] as List?;

            if (coordinates != null && coordinates.length >= 2) {
              final List<LatLng> points = coordinates.map((c) {
                final lon = (c[0] as num).toDouble();
                final lat = (c[1] as num).toDouble();
                return LatLng(lat, lon);
              }).toList();

              final legs = r['legs'] as List?;
              String summary = '';
              if (legs != null && legs.isNotEmpty) {
                summary = legs.first['summary']?.toString() ?? '';
              }

              parsedRoutes.add(
                RouteInfo(
                  points: points,
                  distanceMeters: distance,
                  durationSeconds: duration,
                  isRoadRoute: true,
                  summary: summary,
                ),
              );
            }
          }
          if (parsedRoutes.isNotEmpty) {
            return parsedRoutes;
          }
        }
      }
    } catch (e) {
      debugPrint('OSRM Query failed for $url: $e');
    }
    return [];
  }

  /// Calculates a proper road-following driving route using OSRM.
  static Future<RouteInfo?> fetchRoadRoute(
    LatLng start,
    LatLng destination,
  ) async {
    final routes = await fetchRoadRoutes(start, destination);
    return routes.isNotEmpty ? routes.first : null;
  }

  /// Computes the shortest perpendicular distance in meters from [point]
  /// to any segment of the [polyline].
  static double distanceToPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return double.infinity;
    if (polyline.length == 1) {
      return const Distance().as(LengthUnit.Meter, point, polyline.first);
    }

    double minDistance = double.infinity;
    const distanceUtil = Distance();

    for (int i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];

      final dist = _pointToSegmentDistance(point, a, b, distanceUtil);
      if (dist < minDistance) {
        minDistance = dist;
      }
    }

    return minDistance;
  }

  /// Calculates perpendicular distance from P to segment AB.
  static double _pointToSegmentDistance(
    LatLng p,
    LatLng a,
    LatLng b,
    Distance distanceUtil,
  ) {
    // Convert to planar projection centered around A for high precision on small scales
    final midLat = (a.latitude + b.latitude) / 2.0;
    final cosLat = cos(midLat * pi / 180.0);

    const metersPerDegreeLat = 110574.0;
    final metersPerDegreeLon = 111320.0 * cosLat;

    final dx = (b.longitude - a.longitude) * metersPerDegreeLon;
    final dy = (b.latitude - a.latitude) * metersPerDegreeLat;

    final segLengthSquared = dx * dx + dy * dy;

    // Segment is essentially a point
    if (segLengthSquared < 1.0) {
      return distanceUtil.as(LengthUnit.Meter, p, a);
    }

    final px = (p.longitude - a.longitude) * metersPerDegreeLon;
    final py = (p.latitude - a.latitude) * metersPerDegreeLat;

    // Project point onto line: t is clamped between 0 and 1
    final t = ((px * dx + py * dy) / segLengthSquared).clamp(0.0, 1.0);

    final closestX = t * dx;
    final closestY = t * dy;

    final distX = px - closestX;
    final distY = py - closestY;

    return sqrt(distX * distX + distY * distY);
  }
}
