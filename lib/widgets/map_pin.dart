import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// A map marker whose pin tip sits exactly on [point] at every zoom level.
///
/// A plain `Icon(Icons.location_on)` marker is centred on the point, so its
/// tip is drawn half a pin below the real location and looks "off" when the
/// map is zoomed. Here the marker is placed above the point and the icon is
/// nudged so the tip of the glyph touches the bottom edge.
Marker pinMarker({
  required LatLng point,
  required Color color,
  double size = 40,
  String? label,
  VoidCallback? onTap,
}) {
  const labelHeight = 20.0;
  final hasLabel = label != null && label.isNotEmpty;
  final width = hasLabel ? 88.0 : size;
  final height = size + (hasLabel ? labelHeight : 0);

  Widget pin = Icon(
    Icons.location_on,
    color: color,
    size: size,
    shadows: const [Shadow(color: Colors.black38, blurRadius: 4)],
  );
  // The location_on glyph's tip is at 22/24 of its box: move it down by 1/12.
  pin = Transform.translate(offset: Offset(0, size / 12), child: pin);

  Widget child = Column(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      if (hasLabel)
        SizedBox(
          height: labelHeight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white, width: 1.5),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 3),
              ],
            ),
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
          ),
        ),
      SizedBox(width: size, height: size, child: pin),
    ],
  );
  if (onTap != null) {
    child = GestureDetector(onTap: onTap, child: child);
  }

  return Marker(
    point: point,
    width: width,
    height: height,
    // The whole widget sits above the point; its bottom edge is the point.
    alignment: Alignment.topCenter,
    child: child,
  );
}

/// Map tiles used across the app.
///
/// OpenStreetMap's standard tiles, identified with the app's own name as the
/// tile usage policy requires. If a tile can't be loaded from OSM (blocked,
/// slow or offline server) the same spot is loaded from Esri's World Street
/// Map instead, so the map never stays grey behind the pins.
TileLayer appTileLayer({TileBuilder? tileBuilder}) => TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  fallbackUrl:
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
      'World_Street_Map/MapServer/tile/{z}/{y}/{x}',
  userAgentPackageName: 'pk.safetyguardian.app',
  maxNativeZoom: 19,
  tileBuilder: tileBuilder,
);

/// Required credit for the map data and tiles.
const String mapAttribution = '© OpenStreetMap contributors · Esri';
