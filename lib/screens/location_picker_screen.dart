import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/routing_service.dart';
import '../widgets/map_pin.dart';

class LocationPickerResult {
  final double latitude;
  final double longitude;
  final String address;

  LocationPickerResult({
    required this.latitude,
    required this.longitude,
    required this.address,
  });
}

class LocationPickerScreen extends StatefulWidget {
  final LatLng? initialPosition;
  final String title;

  const LocationPickerScreen({
    super.key,
    this.initialPosition,
    this.title = 'Pick Drop Location',
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController _mapController = MapController();
  LatLng? _picked;
  String _address = '';
  bool _resolving = false;
  Future<void>? _pendingResolve;
  int _resolveToken = 0;

  // Default fallback: Attock, Pakistan (where COMSATS Attock is).
  static const LatLng _fallback = LatLng(33.7710, 72.3596);

  @override
  void initState() {
    super.initState();
    _picked = widget.initialPosition ?? _fallback;
    _resolveAddress(_picked!);
    _centerOnUserIfPossible();
  }

  Future<void> _centerOnUserIfPossible() async {
    if (widget.initialPosition != null) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 5));
      final here = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() => _picked = here);
      _mapController.move(here, 16);
      await _resolveAddress(here);
    } catch (_) {}
  }

  static String _coords(LatLng pos) =>
      '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';

  Future<void> _resolveAddress(LatLng pos) {
    final token = ++_resolveToken; // ignore answers for older taps
    final future = _doResolve(pos, token);
    _pendingResolve = future;
    return future;
  }

  Future<void> _doResolve(LatLng pos, int token) async {
    if (mounted) setState(() => _resolving = true);
    String addr;
    try {
      addr = await RoutingService.reverseGeocode(pos)
          .timeout(const Duration(seconds: 10));
      if (addr.trim().isEmpty || addr.startsWith('Location (')) {
        addr = _coords(pos);
      }
    } catch (_) {
      addr = _coords(pos);
    }
    if (!mounted || token != _resolveToken) return;
    setState(() {
      _address = addr;
      _resolving = false;
    });
  }

  void _onTap(LatLng pos) {
    setState(() => _picked = pos);
    _resolveAddress(pos);
  }

  Future<void> _confirm() async {
    if (_picked == null) return;
    // Wait for the address of the picked point (max ~10s) so the report
    // never stores a "Loading address..." placeholder.
    if (_resolving && _pendingResolve != null) {
      try {
        await _pendingResolve!.timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
    if (!mounted) return;
    if (_address.trim().isEmpty || _resolving) {
      _address = _coords(_picked!);
    }
    Navigator.pop(
      context,
      LocationPickerResult(
        latitude: _picked!.latitude,
        longitude: _picked!.longitude,
        address: _address,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _picked ?? _fallback,
              initialZoom: 14,
              onTap: (tapPosition, point) => _onTap(point),
            ),
            children: [
              // OpenStreetMap tiles. OSM blocks apps that identify as
              // 'com.example...', so a real app id is sent instead.
              appTileLayer(),
              if (_picked != null)
                MarkerLayer(
                  markers: [
                    pinMarker(point: _picked!, color: Colors.red, size: 44),
                  ],
                ),
            ],
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Card(
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: Color(0xFF1D4ED8)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _resolving
                          ? const Text(
                              'Resolving address…',
                              style: TextStyle(fontStyle: FontStyle.italic),
                            )
                          : Text(
                              _address.isEmpty
                                  ? 'Tap the map to pick a place'
                                  : _address,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Map data attribution (required by OpenStreetMap / CARTO).
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              color: Colors.white70,
              child: const Text(
                mapAttribution,
                style: TextStyle(fontSize: 10, color: Colors.black87),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: ElevatedButton.icon(
          icon: const Icon(Icons.check),
          label: const Text('Use This Location'),
          onPressed: _picked == null ? null : _confirm,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1D4ED8),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }
}
