import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import '../models/graphhopper_response.dart';

class RoutingService {
  static const String graphHopperBaseUrl = 'http://157.180.38.147:8989';

  /// Dobija rutu sa GraphHopper servera
  Future<GraphHopperResponse?> getRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    String profile = 'car',
  }) async {
    try {
      // GraphHopper API zahteva multiple 'point' parametara
      final uri = Uri.parse(
        '$graphHopperBaseUrl/route?point=$fromLat,$fromLon&point=$toLat,$toLon&profile=$profile&instructions=true&calc_points=true&points_encoded=true',
      );

      print('📡 Pozivam GraphHopper API: $uri');

      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw Exception('Timeout'),
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('✅ GraphHopper response primljen');
        return GraphHopperResponse.fromJson(data);
      } else {
        print('❌ GraphHopper greška: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('❌ Greška pri pozivu GraphHopper-a: $e');
      return null;
    }
  }

  /// Dekoduje encoded polyline iz GraphHopper-a
  List<LatLng> decodePolyline(String encoded, {double precision = 100000.0}) {
    final List<LatLng> points = [];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int b;
      int shift = 0;
      int result = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / precision, lng / precision));
    }

    return points;
  }

  /// Dobija LatLng tačke iz GraphHopper response-a
  List<LatLng> getRoutePoints(GraphHopperResponse response) {
    if (response.paths.isEmpty) return [];
    final path = response.paths.first;
    return decodePolyline(path.points, precision: path.pointsEncodedMultiplier);
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
