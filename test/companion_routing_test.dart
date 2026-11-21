import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:safety_guardian/services/routing_service.dart';

void main() {
  group('RoutingService Geometry & Deviation Tests', () {
    test('distanceToPolyline returns 0 for a point exactly on the segment', () {
      final polyline = [
        const LatLng(33.7700, 72.3500),
        const LatLng(33.7700, 72.3600),
      ];
      // Point midway on the segment
      final onLine = const LatLng(33.7700, 72.3550);

      final distance = RoutingService.distanceToPolyline(onLine, polyline);
      expect(distance, lessThan(1.0)); // within 1 meter
    });

    test('distanceToPolyline correctly calculates perpendicular offset', () {
      final polyline = [
        const LatLng(33.7700, 72.3500),
        const LatLng(33.7700, 72.3600),
      ];

      // Point offset north by roughly ~110 meters (~0.001 degrees latitude)
      final offsetPoint = const LatLng(33.7710, 72.3550);

      final distance = RoutingService.distanceToPolyline(offsetPoint, polyline);
      expect(distance, greaterThan(100.0));
      expect(distance, lessThan(120.0));
    });

    test('distanceToPolyline handles empty or single point polylines', () {
      expect(RoutingService.distanceToPolyline(const LatLng(0, 0), []), double.infinity);

      final singlePoint = [const LatLng(33.7700, 72.3500)];
      final testPoint = const LatLng(33.7700, 72.3500);
      expect(RoutingService.distanceToPolyline(testPoint, singlePoint), 0.0);
    });
  });

  group('RouteInfo Formatting Tests', () {
    test('formats meters and kilometers properly', () {
      final shortRoute = RouteInfo(
        points: [const LatLng(0, 0), const LatLng(0, 0.005)],
        distanceMeters: 550.0,
        durationSeconds: 120.0,
      );
      expect(shortRoute.formattedDistance, '550 m');
      expect(shortRoute.formattedDuration, '2 mins');

      final longRoute = RouteInfo(
        points: [const LatLng(0, 0), const LatLng(1, 1)],
        distanceMeters: 14250.0,
        durationSeconds: 4200.0, // 70 mins = 1 hr 10 mins
      );
      expect(longRoute.formattedDistance, '14.3 km');
      expect(longRoute.formattedDuration, '1 hr 10 mins');
    });

    test('generates valid ETA timestamp string', () {
      final route = RouteInfo(
        points: [],
        distanceMeters: 1000,
        durationSeconds: 300,
      );
      expect(route.etaTimestamp, contains(RegExp(r'\d{1,2}:\d{2}\s*(AM|PM)')));
    });
  });

  group('PlaceSuggestion Tests', () {
    test('fullAddress joins title and subtitle', () {
      final s1 = PlaceSuggestion(
        title: 'F-6 Markaz',
        subtitle: 'Islamabad, Pakistan',
        latitude: 33.7297,
        longitude: 73.0746,
      );
      expect(s1.fullAddress, 'F-6 Markaz, Islamabad, Pakistan');

      final s2 = PlaceSuggestion(
        title: 'Attock City',
        subtitle: '',
        latitude: 33.7667,
        longitude: 72.3667,
      );
      expect(s2.fullAddress, 'Attock City');
    });

    test('formattedDistanceFrom calculates distance correctly', () {
      final s = PlaceSuggestion(
        title: 'Destination Spot',
        subtitle: '',
        latitude: 33.7700,
        longitude: 72.3600,
      );
      // Same point
      expect(s.formattedDistanceFrom(const LatLng(33.7700, 72.3600)), '0 m away');

      // ~550m away
      final originNear = const LatLng(33.7750, 72.3600);
      expect(s.formattedDistanceFrom(originNear), contains('away'));

      // Null origin returns empty string
      expect(s.formattedDistanceFrom(null), '');
    });

    test('RouteInfo tracks isRoadRoute flag', () {
      final roadRoute = RouteInfo(
        points: [const LatLng(0, 0), const LatLng(1, 1)],
        distanceMeters: 500,
        durationSeconds: 60,
        isRoadRoute: true,
      );
      expect(roadRoute.isRoadRoute, isTrue);

      final fallbackRoute = RouteInfo(
        points: [const LatLng(0, 0), const LatLng(1, 1)],
        distanceMeters: 500,
        durationSeconds: 60,
        isRoadRoute: false,
      );
      expect(fallbackRoute.isRoadRoute, isFalse);
    });

    test('RouteInfo stores and reads optional summary', () {
      final route = RouteInfo(
        points: [const LatLng(0, 0), const LatLng(1, 1)],
        distanceMeters: 1000,
        durationSeconds: 120,
        summary: 'GT Road',
      );
      expect(route.summary, 'GT Road');
    });

    test('reverseGeocode returns non-empty readable string', () async {
      final res = await RoutingService.reverseGeocode(const LatLng(33.7710, 72.3596));
      expect(res, isNotEmpty);
      expect(res, isNot(contains('Could not resolve')));
    });
  });
}
