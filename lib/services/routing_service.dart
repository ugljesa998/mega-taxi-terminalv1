import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

class RoutingService {
  static const String baseUrl = 'http://157.180.38.147:8083';

  Future<List<LatLng>?> getRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/routing/path').replace(
        queryParameters: {
          'fromLat': fromLat.toString(),
          'fromLon': fromLon.toString(),
          'toLat': toLat.toString(),
          'toLon': toLon.toString(),
        },
      );

      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Timeout'),
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routePoints = _parseRoutePoints(data);
        return routePoints.isEmpty ? null : routePoints;
      }
      return null;
    } catch (e) {
      print('❌ Greška: $e');
      return null;
    }
  }

  List<LatLng> _parseRoutePoints(Map<String, dynamic> data) {
    final List<LatLng> points = [];

    try {
      if (data.containsKey('path') && data['path'] is List) {
        final pathData = data['path'] as List;
        for (var coord in pathData) {
          if (coord is List && coord.length >= 2) {
            final lat = coord[0] as num;
            final lon = coord[1] as num;
            points.add(LatLng(lat.toDouble(), lon.toDouble()));
          }
        }
        return points;
      }

      if (data.containsKey('paths') && data['paths'] is List) {
        final paths = data['paths'] as List;
        if (paths.isNotEmpty) {
          final path = paths[0] as Map<String, dynamic>;
          if (path.containsKey('points')) {
            final pointsData = path['points'];
            if (pointsData is Map && pointsData.containsKey('coordinates')) {
              final coordinates = pointsData['coordinates'] as List;
              for (var coord in coordinates) {
                if (coord is List && coord.length >= 2) {
                  final lon = coord[0] as num;
                  final lat = coord[1] as num;
                  points.add(LatLng(lat.toDouble(), lon.toDouble()));
                }
              }
            }
          }
        }
      }
    } catch (e) {
      print('❌ Parse greška: $e');
    }

    return points;
  }

  double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Radius Zemlje u metrima
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) *
            cos(_toRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  double _toRadians(double degrees) => degrees * pi / 180.0;
}
