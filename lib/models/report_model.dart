import 'package:cloud_firestore/cloud_firestore.dart';

class ReportModel {
  final String? id;
  final String userId;
  final String userEmail;
  final String category;
  final String description;
  final double latitude;
  final double longitude;
  final String address;
  final List<String> imageUrls;
  final DateTime timestamp;
  final String status;
  final String priority;

  // AI Prioritization Fields (optional for safe compatibility with existing/old reports)
  final int? severityScore;
  final String? reason;
  final List<String>? detectedFactors;
  final bool? immediateDanger;
  final bool? violenceDetected;
  final bool? weaponDetected;
  final bool? injuryDetected;
  final bool? threatDetected;
  final DateTime? priorityAnalyzedAt;
  
  ReportModel({
    this.id,
    required this.userId,
    required this.userEmail,
    required this.category,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.imageUrls,
    required this.timestamp,
    required this.status,
    required this.priority,
    this.severityScore,
    this.reason,
    this.detectedFactors,
    this.immediateDanger,
    this.violenceDetected,
    this.weaponDetected,
    this.injuryDetected,
    this.threatDetected,
    this.priorityAnalyzedAt,
  });
  
  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'userEmail': userEmail,
      'category': category,
      'description': description,
      'location': GeoPoint(latitude, longitude),
      'address': address,
      'images': imageUrls,
      'timestamp': Timestamp.fromDate(timestamp),
      'status': status,
      'priority': priority,
      if (severityScore != null) 'severityScore': severityScore,
      if (reason != null) 'reason': reason,
      if (detectedFactors != null) 'detectedFactors': detectedFactors,
      if (immediateDanger != null) 'immediateDanger': immediateDanger,
      if (violenceDetected != null) 'violenceDetected': violenceDetected,
      if (weaponDetected != null) 'weaponDetected': weaponDetected,
      if (injuryDetected != null) 'injuryDetected': injuryDetected,
      if (threatDetected != null) 'threatDetected': threatDetected,
      if (priorityAnalyzedAt != null)
        'priorityAnalyzedAt': Timestamp.fromDate(priorityAnalyzedAt!),
    };
  }
  
  static DateTime? _parseDateTime(dynamic val) {
    if (val is Timestamp) return val.toDate();
    if (val is DateTime) return val;
    if (val is String) return DateTime.tryParse(val);
    return null;
  }
  
  factory ReportModel.fromMap(String id, Map<String, dynamic> map) {
    return ReportModel(
      id: id,
      userId: map['userId'] ?? '',
      userEmail: map['userEmail'] ?? '',
      category: map['category'] ?? '',
      description: map['description'] ?? '',
      latitude: (map['location'] as GeoPoint?)?.latitude ??
          (map['latitude'] as num?)?.toDouble() ??
          0.0,
      longitude: (map['location'] as GeoPoint?)?.longitude ??
          (map['longitude'] as num?)?.toDouble() ??
          0.0,
      address: map['address'] ?? '',
      imageUrls: List<String>.from(map['images'] ?? []),
      timestamp: _parseDateTime(map['timestamp']) ?? DateTime.now(),
      status: map['status'] ?? 'pending',
      priority: (map['priority'] ?? 'MEDIUM').toString(),
      severityScore: (map['severityScore'] as num?)?.toInt(),
      reason: map['reason'] as String?,
      detectedFactors: map['detectedFactors'] != null
          ? List<String>.from(map['detectedFactors'])
          : null,
      immediateDanger: map['immediateDanger'] as bool?,
      violenceDetected: map['violenceDetected'] as bool?,
      weaponDetected: map['weaponDetected'] as bool?,
      injuryDetected: map['injuryDetected'] as bool?,
      threatDetected: map['threatDetected'] as bool?,
      priorityAnalyzedAt: _parseDateTime(map['priorityAnalyzedAt']),
    );
  }
}