import 'dart:math';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:geolocator/geolocator.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final LocationService _locationService = LocationService();
  final RoutingService _routingService = RoutingService();

  MaplibreMapController? _mapController;
  Position? _currentPosition;
  LatLng? _snappedPosition; // Snapped pozicija za smooth prikaz
  double _currentHeading = 0.0;
  double _currentBearing = 0.0; // Bearing izračunat iz rute
  double _smoothSpeed = 0.0; // Smooth brzina (km/h)

  List<LatLng> _routePoints = [];
  LatLng? _destination;
  bool _isLoadingRoute = false;
  bool _isRerouting = false;
  bool _isLoading = true;
  bool _is3DMode = true;
  bool _isAutoFollowing = true;

  Line? _routeLine;
  Symbol? _destinationSymbol;

  static const double _navigationZoomLevel = 17.0;
  static const double _tiltAngle = 60.0;
  static const double _rerouteDistanceThreshold = 30.0;

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    final hasPermission = await _locationService.requestPermissions();
    if (!hasPermission) {
      _showError('GPS permisije nisu odobrene');
      return;
    }

    final position = await _locationService.getCurrentPosition();
    if (position == null) {
      _showError('Ne mogu da dobijem GPS poziciju');
      return;
    }

    setState(() {
      _currentPosition = position;
      _currentHeading = position.heading;
      _isLoading = false;
    });

    _startLocationTracking();
  }

  void _startLocationTracking() {
    _locationService.startTracking();
    _locationService.positionStream.listen((Position position) {
      _updateCarPosition(position);
    });
  }

  /// SMOOTH TRACKING - ažurira poziciju i prati SNAPPED poziciju
  void _updateCarPosition(Position position) {
    setState(() {
      _currentPosition = position;

      // SPEEDOMETAR - Smooth brzina (kao Mapbox)
      double speedKmh = position.speed * 3.6; // m/s → km/h

      // GPS ŠUM FILTER - agresivniji filter za stojeće stanje
      // GPS u zgradi može pokazati 5-10 km/h dok stojimo!
      if (speedKmh < 2.0) {
        speedKmh = 0.0; // Ispod 5 km/h = stojiš
      }

      // Exponential moving average za smooth prikaz
      _smoothSpeed = (_smoothSpeed * 0.8) + (speedKmh * 0.2);

      // SNAP-TO-ROAD - "lepi" poziciju za rutu! (ako Mapbox)
      if (_routePoints.isNotEmpty) {
        final rawGPS = LatLng(position.latitude, position.longitude);
        _snappedPosition = _snapToRoute(position);

        // Pin je UVEK na ruti dok je navigacija aktivna - vozači ne voze po trotoaru!
        _snappedPosition ??= rawGPS;

        // DEBUG: Udaljenost između raw GPS i snapped pozicije
        final snapDistance = _routingService.calculateDistance(
          rawGPS.latitude,
          rawGPS.longitude,
          _snappedPosition!.latitude,
          _snappedPosition!.longitude,
        );
        print(
          '🛣️ Snap: ${snapDistance.toStringAsFixed(1)}m razlike | '
          'Ruta tačaka: ${_routePoints.length}',
        );

        // BEARING CALCULATION - samo kad se ZAISTA kreće (speed > 5 km/h = 1.4 m/s)
        // GPS u zgradi može pokazati lažnu brzinu!
        if (position.speed > 1.4 &&
            speedKmh > 5.0 &&
            _snappedPosition != null) {
          _calculateBearingFromRoute(_snappedPosition!);
          _currentHeading = _currentBearing;
        } else if (position.heading >= 0) {
          // Kad stojimo ili spora brzina, koristi GPS heading
          _currentHeading = position.heading;
        }
      } else {
        _snappedPosition = LatLng(position.latitude, position.longitude);
        // Bez rute, koristi GPS heading
        if (position.heading >= 0) {
          _currentHeading = position.heading;
        }
      }
    });

    // SMOOTH praćenje - koristi SNAPPED poziciju (ne sirovi GPS!)
    if (_isAutoFollowing && _mapController != null) {
      _centerMapOnUser();
    }

    _checkIfNeedsRerouting();
  }

  void _onMapCreated(MaplibreMapController controller) {
    _mapController = controller;
    if (_currentPosition != null) {
      _centerMapOnUser();
    }
  }

  Future<void> _centerMapOnUser() async {
    if (_mapController == null || _currentPosition == null) return;

    // Koristi SNAPPED poziciju za smooth praćenje (bez lutanja po zgradama)
    final targetPosition =
        _snappedPosition ??
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

    await _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: targetPosition,
          zoom: _navigationZoomLevel,
          bearing: _currentHeading,
          tilt: _is3DMode ? _tiltAngle : 0.0,
        ),
      ),
    );
  }

  void _toggle3DMode() {
    setState(() => _is3DMode = !_is3DMode);
    _centerMapOnUser();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_is3DMode ? '🎮 3D Navigacija' : '📱 2D Mapa'),
        duration: const Duration(seconds: 1),
        backgroundColor: _is3DMode ? Colors.blue : Colors.grey,
      ),
    );
  }

  Future<void> _testRouteTrnska() async {
    if (_currentPosition == null) {
      _showError('GPS pozicija nije dostupna');
      return;
    }

    setState(() => _isLoadingRoute = true);

    const destLat = 44.80239533259546;
    const destLon = 20.476799408890763;

    try {
      final routePoints = await _routingService.getRoute(
        fromLat: _currentPosition!.latitude,
        fromLon: _currentPosition!.longitude,
        toLat: destLat,
        toLon: destLon,
      );

      if (routePoints != null && routePoints.isNotEmpty) {
        setState(() {
          _routePoints = routePoints;
          _destination = LatLng(destLat, destLon);
          _isLoadingRoute = false;
        });

        await _drawRoute();
        await _addDestinationMarker();
        await _fitRouteBounds();

        Future.delayed(const Duration(seconds: 2), () {
          _centerMapOnUser();
          setState(() => _isAutoFollowing = true);
        });

        _showSuccess('Ruta pronađena: ${routePoints.length} tačaka');
      } else {
        setState(() => _isLoadingRoute = false);
        _showError('Ruta nije pronađena');
      }
    } catch (e) {
      setState(() => _isLoadingRoute = false);
      _showError('Greška: $e');
    }
  }

  Future<void> _drawRoute() async {
    if (_mapController == null || _routePoints.isEmpty) return;

    if (_routeLine != null) {
      await _mapController!.removeLine(_routeLine!);
    }

    // Iscrtavanje rute sa podacima koji se dobijaju sa API-ja
    // Podaci su u formatu List<LatLng> koje dobijamo od routing servisa
    _routeLine = await _mapController!.addLine(
      LineOptions(
        geometry: _routePoints,
        lineColor: '#2196F3', // Plava boja - jasna i vidljiva
        lineWidth: 8.0, // Debljina 8 piksela - dovoljno jasna na ulici
        lineOpacity: 0.95, // Visoka opacity za bolju vidljivost
      ),
    );
  }

  Future<void> _addDestinationMarker() async {
    if (_mapController == null || _destination == null) return;

    if (_destinationSymbol != null) {
      await _mapController!.removeSymbol(_destinationSymbol!);
    }

    _destinationSymbol = await _mapController!.addSymbol(
      SymbolOptions(
        geometry: _destination!,
        iconImage: 'marker-15',
        iconSize: 2.5,
        iconColor: '#FF0000',
      ),
    );
  }

  Future<void> _fitRouteBounds() async {
    if (_mapController == null || _routePoints.isEmpty) return;

    double minLat = _routePoints.first.latitude;
    double maxLat = _routePoints.first.latitude;
    double minLng = _routePoints.first.longitude;
    double maxLng = _routePoints.first.longitude;

    for (var point in _routePoints) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    await _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        left: 50,
        top: 50,
        right: 50,
        bottom: 50,
      ),
    );
  }

  Future<void> _clearRoute() async {
    if (_routeLine != null && _mapController != null) {
      await _mapController!.removeLine(_routeLine!);
    }
    if (_destinationSymbol != null && _mapController != null) {
      await _mapController!.removeSymbol(_destinationSymbol!);
    }

    setState(() {
      _routePoints = [];
      _destination = null;
      _routeLine = null;
      _destinationSymbol = null;
    });

    _centerMapOnUser();
    _showSuccess('Ruta obrisana');
  }

  void _checkIfNeedsRerouting() {
    if (_routePoints.isEmpty || _destination == null || _isRerouting) return;
    if (_currentPosition == null) return;

    final distanceToDestination = _routingService.calculateDistance(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _destination!.latitude,
      _destination!.longitude,
    );

    if (distanceToDestination < 10.0) return;

    final distanceFromRoute = _getDistanceFromRoute(
      LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
    );

    if (distanceFromRoute > _rerouteDistanceThreshold) {
      _performRerouting();
    }
  }

  double _getDistanceFromRoute(LatLng position) {
    if (_routePoints.isEmpty) return 0.0;

    double minDistance = double.infinity;
    for (var point in _routePoints) {
      final distance = _routingService.calculateDistance(
        position.latitude,
        position.longitude,
        point.latitude,
        point.longitude,
      );
      if (distance < minDistance) minDistance = distance;
    }
    return minDistance;
  }

  /// SNAP-TO-ROAD - "Lepi" GPS poziciju za rutu (kao Mapbox - pin UVEK na putu!)
  LatLng? _snapToRoute(Position position) {
    if (_routePoints.isEmpty) return null;

    double minDistance = double.infinity;
    LatLng? closestPoint;
    int closestIndex = -1;

    // 1. Pronađi najbližu tačku na ruti
    for (int i = 0; i < _routePoints.length; i++) {
      final distance = _routingService.calculateDistance(
        position.latitude,
        position.longitude,
        _routePoints[i].latitude,
        _routePoints[i].longitude,
      );

      if (distance < minDistance) {
        minDistance = distance;
        closestPoint = _routePoints[i];
        closestIndex = i;
      }
    }

    if (closestPoint == null) return null;

    // 2. Ako je blizu (50m), koristi INTERPOLACIJU za smooth prikaz
    const double interpolationThreshold = 50.0; // metara
    if (minDistance <= interpolationThreshold) {
      // DEBUG
      print('✅ SNAP: ${minDistance.toStringAsFixed(1)}m - INTERPOLACIJA');

      // INTERPOLACIJA - projekcija GPS-a na liniju između 2 tačke
      if (closestIndex < _routePoints.length - 1) {
        final nextPoint = _routePoints[closestIndex + 1];
        return _projectPointOnLine(
          LatLng(position.latitude, position.longitude),
          closestPoint,
          nextPoint,
        );
      }
      return closestPoint;
    } else {
      // 3. Ako je daleko (50m+), snap na najbližu tačku BEZ interpolacije
      // PIN OSTAJE NA RUTI - vozači ne voze po trotoaru! (kao Mapbox)
      print(
        '⚠️ SNAP: ${minDistance.toStringAsFixed(1)}m - DALEKO, snap na najbližu',
      );
      return closestPoint;
    }
  }

  /// Projekcija tačke na liniju (perpendikular)
  LatLng _projectPointOnLine(LatLng point, LatLng lineStart, LatLng lineEnd) {
    final dx = lineEnd.longitude - lineStart.longitude;
    final dy = lineEnd.latitude - lineStart.latitude;

    if (dx == 0 && dy == 0) return lineStart;

    // Parametar t (0-1) određuje poziciju na liniji
    final t =
        ((point.longitude - lineStart.longitude) * dx +
            (point.latitude - lineStart.latitude) * dy) /
        (dx * dx + dy * dy);

    final clampedT = t.clamp(0.0, 1.0); // Odrezi van linije

    return LatLng(
      lineStart.latitude + clampedT * dy,
      lineStart.longitude + clampedT * dx,
    );
  }

  /// ROTACIJA PIN-A - Izračunava bearing prema sledećoj tački na ruti
  void _calculateBearingFromRoute(LatLng currentPos) {
    if (_routePoints.length < 2) return;

    // 1. Pronađi najbližu tačku na ruti
    int closestIndex = 0;
    double minDist = double.infinity;

    for (int i = 0; i < _routePoints.length; i++) {
      final dist = _routingService.calculateDistance(
        currentPos.latitude,
        currentPos.longitude,
        _routePoints[i].latitude,
        _routePoints[i].longitude,
      );
      if (dist < minDist) {
        minDist = dist;
        closestIndex = i;
      }
    }

    // 2. Uzmi SLEDEĆU tačku za bearing (ne prethodnu!)
    if (closestIndex < _routePoints.length - 1) {
      final nextPoint = _routePoints[closestIndex + 1];
      final dy = nextPoint.latitude - currentPos.latitude;
      final dx = nextPoint.longitude - currentPos.longitude;

      // 3. atan2 za bearing (u stepenima)
      _currentBearing = atan2(dx, dy) * 180 / pi;
    }
  }

  Future<void> _performRerouting() async {
    if (_destination == null || _currentPosition == null) return;

    setState(() => _isRerouting = true);

    try {
      final routePoints = await _routingService.getRoute(
        fromLat: _currentPosition!.latitude,
        fromLon: _currentPosition!.longitude,
        toLat: _destination!.latitude,
        toLon: _destination!.longitude,
      );

      if (routePoints != null && routePoints.isNotEmpty) {
        setState(() {
          _routePoints = routePoints;
          _isRerouting = false;
        });

        await _drawRoute();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🔄 Ruta ažurirana'),
            duration: Duration(seconds: 1),
            backgroundColor: Colors.orange,
          ),
        );
      } else {
        setState(() => _isRerouting = false);
      }
    } catch (e) {
      setState(() => _isRerouting = false);
    }
  }

  void _showError(String message) {
    setState(() => _isLoading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('❌ $message'), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ $message'), backgroundColor: Colors.green),
    );
  }

  /// Boja brzine po opsegu (kao Mapbox)
  Color _getSpeedColor() {
    if (_smoothSpeed < 5) return Colors.grey; // Peške/stojimo
    if (_smoothSpeed < 30) return Colors.orange; // Gužva
    return Colors.green; // Normalna vožnja
  }

  @override
  void dispose() {
    _locationService.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🚕 Mega Taxi Terminal'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('📡 Tražim GPS signal...'),
                ],
              ),
            )
          : Stack(
              children: [
                MaplibreMap(
                  styleString: 'https://tiles.openfreemap.org/styles/liberty',
                  initialCameraPosition: CameraPosition(
                    target: _currentPosition != null
                        ? LatLng(
                            _currentPosition!.latitude,
                            _currentPosition!.longitude,
                          )
                        : const LatLng(44.7866, 20.4489),
                    zoom: _navigationZoomLevel,
                    tilt: _is3DMode ? _tiltAngle : 0.0,
                  ),
                  onMapCreated: _onMapCreated,
                  onMapClick: (point, latLng) {
                    if (_isAutoFollowing) {
                      setState(() => _isAutoFollowing = false);
                    }
                  },
                  myLocationEnabled: true,
                  myLocationTrackingMode: _isAutoFollowing
                      ? MyLocationTrackingMode.tracking
                      : MyLocationTrackingMode.none,
                  myLocationRenderMode: MyLocationRenderMode.normal,
                  compassEnabled: true,
                  minMaxZoomPreference: const MinMaxZoomPreference(5.0, 20.0),
                ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '📍 ${_currentPosition?.latitude.toStringAsFixed(6) ?? "---"}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          '📍 ${_currentPosition?.longitude.toStringAsFixed(6) ?? "---"}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          '🧭 ${_currentHeading.toStringAsFixed(1)}°',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          '🏃 ${_smoothSpeed.toStringAsFixed(0)} km/h',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: _getSpeedColor(),
                          ),
                        ),
                        if (_isRerouting)
                          const Text(
                            '🔄 Re-routing...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.orange,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (!_isLoadingRoute && _routePoints.isEmpty)
            FloatingActionButton.extended(
              heroTag: 'test_route',
              onPressed: _testRouteTrnska,
              backgroundColor: Colors.green,
              icon: const Icon(Icons.route),
              label: const Text('Test Ruta'),
            ),
          if (_routePoints.isNotEmpty)
            FloatingActionButton.extended(
              heroTag: 'clear_route',
              onPressed: _clearRoute,
              backgroundColor: Colors.red,
              icon: const Icon(Icons.clear),
              label: const Text('Obriši'),
            ),
          if (_isLoadingRoute)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: CircularProgressIndicator(),
            ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: '3d_toggle',
            mini: true,
            onPressed: _toggle3DMode,
            backgroundColor: _is3DMode ? Colors.blue : Colors.grey[300],
            child: Icon(
              _is3DMode ? Icons.view_in_ar : Icons.map,
              color: _is3DMode ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'recenter',
            onPressed: () {
              setState(() => _isAutoFollowing = true);
              _centerMapOnUser();
            },
            backgroundColor: _isAutoFollowing ? Colors.blue : Colors.grey[300],
            child: Icon(
              Icons.my_location,
              color: _isAutoFollowing ? Colors.white : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}
