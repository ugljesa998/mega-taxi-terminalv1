import 'dart:math';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:geolocator/geolocator.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../models/graphhopper_response.dart';
import '../widgets/navigation_instructions_panel.dart';
import '../widgets/current_instruction_banner.dart';

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
  LatLng? _snappedPosition; // 📍 SNAP-TO-ROAD: Pozicija "zakačena" na rutu
  double _currentHeading = 0.0;

  List<LatLng> _routePoints = [];
  LatLng? _destination;
  bool _isLoadingRoute = false;
  bool _isRerouting = false;
  bool _isLoading = true;
  bool _is3DMode = false; // Podrazumevano 2D
  bool _isAutoFollowing = true;
  int _currentMapStyleIndex = 0;

  Line? _routeLine;
  Symbol? _destinationSymbol;
  Circle?
  _userLocationCircle; // 📍 SNAP-TO-ROAD: Custom location marker (kao LocationComponent)
  Circle? _userLocationPulse; // 📍 Pulsing circle oko markera za vidljivost
  Path? _currentRoutePath;
  int _currentInstructionIndex =
      1; // Počinjemo od 1 (preskačemo prvu instrukciju)
  double _instructionThresholdDistance =
      80.0; // Metara pre instrukcije za prikaz

  static const double _navigationZoomLevel = 17.0;
  static const double _tiltAngle = 60.0;
  static const double _rerouteDistanceThreshold = 30.0;

  // Dostupni stilovi mapa - optimizovani za taksiste
  final List<Map<String, String>> _mapStyles = [
    {
      'name': '🗺️ OSM Bright',
      'url': 'https://tiles.openfreemap.org/styles/bright',
      'description': 'Svetla mapa sa jasnim putevima',
    },
    {
      'name': '🌆 OSM Liberty',
      'url': 'https://tiles.openfreemap.org/styles/liberty',
      'description': 'Balanced stil sa dobrim kontrastom',
    },
    {
      'name': '🛣️ Positron',
      'url': 'https://tiles.openfreemap.org/styles/positron',
      'description': 'Minimalistički - fokus na puteve',
    },
    {
      'name': '🌙 Dark Matter',
      'url': 'https://tiles.openfreemap.org/styles/dark-matter',
      'description': 'Tamna mapa - noćna vožnja',
    },
  ];

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
      setState(() {
        _currentPosition = position;
        _currentHeading = position.heading;

        // 📍 SNAP-TO-ROAD: Ako imamo rutu, "zakači" poziciju na rutu
        if (_routePoints.isNotEmpty) {
          _snappedPosition = _snapToRoute(
            LatLng(position.latitude, position.longitude),
          );
        } else {
          _snappedPosition = null;
        }
      });

      // 📍 SNAP-TO-ROAD: Ažuriraj marker poziciju (kao forceLocationUpdate)
      _updateUserLocationMarker();

      if (_isAutoFollowing && _mapController != null) {
        _centerMapOnUser();
      }

      _checkIfNeedsRerouting();
      _checkInstructionProgress();
    });
  }

  void _onMapCreated(MaplibreMapController controller) async {
    _mapController = controller;

    // 📍 SNAP-TO-ROAD: Kreiraj custom location marker nakon što se mapa učita
    if (_currentPosition != null) {
      // Mali delay da se mapa sigurno učita
      await Future.delayed(const Duration(milliseconds: 500));
      await _updateUserLocationMarker();
      await _centerMapOnUser();
    }
  }

  /// 📍 SNAP-TO-ROAD: Ažurira custom location marker (kao locationComponent.forceLocationUpdate)
  /// Identično Android LocationComponent sa RenderMode.GPS
  Future<void> _updateUserLocationMarker() async {
    if (_mapController == null || _currentPosition == null) return;

    // Koristi snapped poziciju ako postoji, inače raw GPS
    final markerPosition =
        _snappedPosition ??
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

    try {
      // Obriši stare markere
      if (_userLocationCircle != null) {
        await _mapController!.removeCircle(_userLocationCircle!);
      }
      if (_userLocationPulse != null) {
        await _mapController!.removeCircle(_userLocationPulse!);
      }

      // 1. Svetlo plavi/sivi accuracy circle (kao u Android verziji)
      _userLocationPulse = await _mapController!.addCircle(
        CircleOptions(
          geometry: markerPosition,
          circleRadius: 15.0, // Accuracy radius
          circleColor: '#78909C', // Siva boja
          circleOpacity: 0.15,
          circleStrokeWidth: 1.5,
          circleStrokeColor: '#78909C',
          circleStrokeOpacity: 0.4,
        ),
      );

      // 2. MALI SIVI PIN u centru (kao GPS tačkica u Android LocationComponent)
      _userLocationCircle = await _mapController!.addCircle(
        CircleOptions(
          geometry: markerPosition,
          circleRadius: 5.0, // Mali radius - tačkica
          circleColor: '#78909C', // Siva boja (kao u Android verziji)
          circleOpacity: 1.0,
          circleStrokeWidth: 2.5,
          circleStrokeColor: '#FFFFFF', // Beli border
          circleStrokeOpacity: 1.0,
        ),
      );
    } catch (e) {
      // Ignoriši greške pri ažuriranju markera
    }
  }

  Future<void> _centerMapOnUser() async {
    if (_mapController == null || _currentPosition == null) return;

    // 📍 SNAP-TO-ROAD: Koristi snapped poziciju ako postoji, inače raw GPS
    final targetPosition =
        _snappedPosition ??
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

    // Ako imamo rutu, rotiramo kameru u pravcu sledeće tačke instrukcije
    double cameraBearing = 0.0;
    if (_routePoints.isNotEmpty && _currentRoutePath != null) {
      cameraBearing = _calculateBearingToNextInstruction();
    }

    await _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: targetPosition,
          zoom: _navigationZoomLevel,
          bearing: cameraBearing, // Rotacija ka sledećoj instrukciji
          tilt: _is3DMode ? _tiltAngle : 0.0,
        ),
      ),
    );
  }

  /// Izračunava bearing (ugao) od trenutne pozicije ka sledećoj tački instrukcije
  double _calculateBearingToNextInstruction() {
    if (_currentPosition == null || _routePoints.isEmpty) return 0.0;
    if (_currentRoutePath == null) return 0.0;

    final instructions = _currentRoutePath!.instructions;
    if (_currentInstructionIndex >= instructions.length) return 0.0;

    final currentInstruction = instructions[_currentInstructionIndex];
    final instructionPointIndex = currentInstruction.interval.first;

    if (instructionPointIndex >= _routePoints.length) return 0.0;

    final targetPoint = _routePoints[instructionPointIndex];

    // 📍 SNAP-TO-ROAD: Koristi snapped poziciju za bearing ako postoji
    final fromPosition =
        _snappedPosition ??
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

    // Izračunavamo bearing od trenutne (snapped) pozicije ka tački instrukcije
    return _calculateBearing(
      fromPosition.latitude,
      fromPosition.longitude,
      targetPoint.latitude,
      targetPoint.longitude,
    );
  }

  /// Izračunava bearing (ugao) između dve tačke
  double _calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final dLon = _toRadians(lon2 - lon1);
    final lat1Rad = _toRadians(lat1);
    final lat2Rad = _toRadians(lat2);

    final y = sin(dLon) * cos(lat2Rad);
    final x =
        cos(lat1Rad) * sin(lat2Rad) - sin(lat1Rad) * cos(lat2Rad) * cos(dLon);

    final bearing = atan2(y, x);
    return (bearing * 180 / pi + 360) % 360; // Konvertuje u stepene (0-360)
  }

  double _toRadians(double degrees) => degrees * pi / 180.0;

  /// 📍 SNAP-TO-ROAD: Projektuje GPS poziciju na najbliži segment rute
  /// Algoritam identičan Android MapLibre Navigation SDK-u
  LatLng? _snapToRoute(LatLng currentPosition) {
    if (_routePoints.isEmpty) return null;
    if (_routePoints.length < 2) return _routePoints.first;

    LatLng? closestPoint;
    double minDistance = double.infinity;

    // Prolazimo kroz sve segmente rute (svaki par susednih tačaka)
    for (int i = 0; i < _routePoints.length - 1; i++) {
      final segmentStart = _routePoints[i];
      final segmentEnd = _routePoints[i + 1];

      // Projektuj trenutnu poziciju na ovaj segment
      final projectedPoint = _projectPointOnSegment(
        currentPosition,
        segmentStart,
        segmentEnd,
      );

      // Izračunaj distancu od trenutne pozicije do projektovane tačke
      final distance = _routingService.calculateDistance(
        currentPosition.latitude,
        currentPosition.longitude,
        projectedPoint.latitude,
        projectedPoint.longitude,
      );

      // Zapamti najbližu tačku
      if (distance < minDistance) {
        minDistance = distance;
        closestPoint = projectedPoint;
      }
    }

    return closestPoint;
  }

  /// 📍 Projektuje tačku na linijski segment (između A i B)
  /// Vraća najbližu tačku na segmentu do zadate tačke
  LatLng _projectPointOnSegment(
    LatLng point,
    LatLng segmentA,
    LatLng segmentB,
  ) {
    // Konvertujemo geografske koordinate u Cartesian za tačniju projekciju
    final px = point.longitude;
    final py = point.latitude;
    final ax = segmentA.longitude;
    final ay = segmentA.latitude;
    final bx = segmentB.longitude;
    final by = segmentB.latitude;

    // Vektor AB
    final abx = bx - ax;
    final aby = by - ay;

    // Vektor AP
    final apx = px - ax;
    final apy = py - ay;

    // Projekcija AP na AB: t = (AP · AB) / |AB|²
    final abLengthSquared = abx * abx + aby * aby;

    if (abLengthSquared == 0) {
      // Segment je zapravo tačka, vrati A
      return segmentA;
    }

    // t predstavlja poziciju na segmentu (0 = A, 1 = B)
    double t = (apx * abx + apy * aby) / abLengthSquared;

    // Ograničavamo t na segment [0, 1]
    t = t.clamp(0.0, 1.0);

    // Projektovana tačka: P' = A + t * AB
    final projectedLng = ax + t * abx;
    final projectedLat = ay + t * aby;

    return LatLng(projectedLat, projectedLng);
  }

  void _toggle3DMode() {
    setState(() => _is3DMode = !_is3DMode);
    _centerMapOnUser();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_is3DMode ? '🎮 3D Pogled' : '📱 2D Mapa'),
        duration: const Duration(seconds: 1),
        backgroundColor: _is3DMode ? Colors.blue : Colors.grey,
      ),
    );
  }

  Future<void> _changeMapStyle() async {
    final selectedIndex = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Izaberi stil mape'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(_mapStyles.length, (index) {
            final style = _mapStyles[index];
            final isSelected = index == _currentMapStyleIndex;
            return ListTile(
              selected: isSelected,
              selectedTileColor: Colors.blue[50],
              leading: Text(
                style['name']!.split(' ')[0],
                style: const TextStyle(fontSize: 24),
              ),
              title: Text(
                style['name']!.substring(style['name']!.indexOf(' ') + 1),
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              subtitle: Text(
                style['description']!,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: isSelected
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => Navigator.pop(context, index),
            );
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Otkaži'),
          ),
        ],
      ),
    );

    if (selectedIndex != null && selectedIndex != _currentMapStyleIndex) {
      setState(() => _currentMapStyleIndex = selectedIndex);

      // Promena stila mape
      if (_mapController != null) {
        await _mapController!.setStyle(_mapStyles[selectedIndex]['url']!);

        // Sačekaj malo da se stil učita, pa ponovo nacrtaj rutu
        await Future.delayed(const Duration(milliseconds: 500));
        if (_routePoints.isNotEmpty) {
          await _drawRoute();
          if (_destination != null) {
            await _addDestinationMarker();
          }
        }
      }

      _showSuccess('Stil promenjen: ${_mapStyles[selectedIndex]['name']}');
    }
  }

  Future<void> _createRouteToDestination(LatLng destination) async {
    if (_currentPosition == null) {
      _showError('GPS pozicija nije dostupna');
      return;
    }

    setState(() => _isLoadingRoute = true);

    try {
      final response = await _routingService.getRoute(
        fromLat: _currentPosition!.latitude,
        fromLon: _currentPosition!.longitude,
        toLat: destination.latitude,
        toLon: destination.longitude,
        profile: 'car',
      );

      if (response != null && response.paths.isNotEmpty) {
        final routePoints = _routingService.getRoutePoints(response);

        if (routePoints.isNotEmpty) {
          setState(() {
            _currentRoutePath = response.paths.first;
            _routePoints = routePoints;
            _destination = destination;
            _isLoadingRoute = false;
            _currentInstructionIndex =
                1; // Počinjemo od druge instrukcije (index 1)

            // 📍 SNAP-TO-ROAD: Odmah snap-uj trenutnu poziciju na novu rutu
            if (_currentPosition != null) {
              _snappedPosition = _snapToRoute(
                LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
              );
            }
          });

          await _drawRoute();
          await _addDestinationMarker();
          await _fitRouteBounds();

          // 📍 SNAP-TO-ROAD: Ažuriraj marker odmah nakon što se kreira ruta
          await _updateUserLocationMarker();

          Future.delayed(const Duration(seconds: 2), () {
            _centerMapOnUser();
            setState(() => _isAutoFollowing = true);
          });

          _showSuccess(
            'Ruta: ${_currentRoutePath!.getDistanceText()} • ${_currentRoutePath!.getTimeText()}',
          );

          // Prikaži prvu aktivnu instrukciju
          _showCurrentInstruction();
        } else {
          setState(() => _isLoadingRoute = false);
          _showError('Ruta nije pronađena');
        }
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

    _routeLine = await _mapController!.addLine(
      LineOptions(
        geometry: _routePoints,
        lineColor: '#4A90E2',
        lineWidth: 6.0,
        lineOpacity: 0.9,
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
      _currentRoutePath = null;
      _currentInstructionIndex = 1;
      _snappedPosition = null; // 📍 SNAP-TO-ROAD: Reset snapped pozicije
    });

    // 📍 SNAP-TO-ROAD: Ažuriraj marker na raw GPS poziciju
    await _updateUserLocationMarker();
    _centerMapOnUser();
    _showSuccess('Ruta obrisana');
  }

  /// Proverava napredak prema sledećoj instrukciji
  void _checkInstructionProgress() {
    if (_currentRoutePath == null || _currentPosition == null) return;
    if (_routePoints.isEmpty) return;

    final instructions = _currentRoutePath!.instructions;

    // Preskačemo ako smo prošli sve instrukcije
    if (_currentInstructionIndex >= instructions.length) return;

    final currentInstruction = instructions[_currentInstructionIndex];

    // Dobijamo tačku na ruti gde se nalazi trenutna instrukcija
    final instructionPointIndex = currentInstruction.interval.first;

    if (instructionPointIndex < _routePoints.length) {
      final instructionPoint = _routePoints[instructionPointIndex];

      // 📍 SNAP-TO-ROAD: Koristi snapped poziciju za tačniju proveru
      final fromPosition =
          _snappedPosition ??
          LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

      final distanceToInstruction = _routingService.calculateDistance(
        fromPosition.latitude,
        fromPosition.longitude,
        instructionPoint.latitude,
        instructionPoint.longitude,
      );

      // Ako smo prošli instrukciju (manje od 20m), prelazimo na sledeću
      if (distanceToInstruction < 20.0) {
        setState(() {
          _currentInstructionIndex++;
        });

        // Prikaži sledeću instrukciju
        if (_currentInstructionIndex < instructions.length) {
          _showCurrentInstruction();
        } else {
          _showSuccess('🏁 Stigli ste na destinaciju!');
        }
      }
      // Ako se približavamo (unutar threshold-a), možemo dodati audio upozorenje
      else if (distanceToInstruction < _instructionThresholdDistance &&
          distanceToInstruction > 20.0) {
        // Ovde možemo dodati audio ili vizuelno upozorenje
      }
    }
  }

  /// Prikazuje trenutnu aktivnu instrukciju
  void _showCurrentInstruction() {
    if (_currentRoutePath == null) return;

    final instructions = _currentRoutePath!.instructions;
    if (_currentInstructionIndex >= instructions.length) return;

    final instruction = instructions[_currentInstructionIndex];

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Text(
              instruction.getInstructionIcon(),
              style: const TextStyle(fontSize: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    instruction.text,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  if (instruction.distance > 0)
                    Text(
                      'Za ${instruction.getDistanceText()}',
                      style: const TextStyle(fontSize: 13),
                    ),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 4),
        backgroundColor: Colors.blue[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
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

  Future<void> _performRerouting() async {
    if (_destination == null || _currentPosition == null) return;

    setState(() => _isRerouting = true);

    try {
      final response = await _routingService.getRoute(
        fromLat: _currentPosition!.latitude,
        fromLon: _currentPosition!.longitude,
        toLat: _destination!.latitude,
        toLon: _destination!.longitude,
        profile: 'car',
      );

      if (response != null && response.paths.isNotEmpty) {
        final routePoints = _routingService.getRoutePoints(response);

        if (routePoints.isNotEmpty) {
          setState(() {
            _currentRoutePath = response.paths.first;
            _routePoints = routePoints;
            _isRerouting = false;
            _currentInstructionIndex =
                1; // Reset na drugu instrukciju posle reroutinga

            // 📍 SNAP-TO-ROAD: Snap-uj na novu re-route-ovanu rutu
            if (_currentPosition != null) {
              _snappedPosition = _snapToRoute(
                LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
              );
            }
          });

          await _drawRoute();

          // 📍 SNAP-TO-ROAD: Ažuriraj marker na novu re-route-ovanu rutu
          await _updateUserLocationMarker();

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🔄 Ruta ažurirana'),
              duration: Duration(seconds: 1),
              backgroundColor: Colors.orange,
            ),
          );

          // Prikaži novu trenutnu instrukciju
          _showCurrentInstruction();
        } else {
          setState(() => _isRerouting = false);
        }
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

  @override
  void dispose() {
    _locationService.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                // Mapa
                MaplibreMap(
                  styleString: _mapStyles[_currentMapStyleIndex]['url']!,
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
                  onMapClick: (point, latLng) async {
                    // Ako već postoji ruta, pitaj korisnika da li želi novu
                    if (_routePoints.isNotEmpty) {
                      final shouldCreate = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Nova ruta?'),
                          content: const Text(
                            'Da li želite da kreirate novu rutu do ove lokacije?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Otkaži'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Kreiraj'),
                            ),
                          ],
                        ),
                      );

                      if (shouldCreate == true) {
                        await _clearRoute();
                        await _createRouteToDestination(latLng);
                      }
                    } else {
                      // Ako nema rute, odmah kreiraj
                      _createRouteToDestination(latLng);
                    }
                  },
                  // 📍 SNAP-TO-ROAD: Isključena built-in strelica, koristimo samo custom marker
                  myLocationEnabled: false,
                  compassEnabled: true,
                  minMaxZoomPreference: const MinMaxZoomPreference(5.0, 20.0),
                ),

                // Veliki banner sa trenutnom instrukcijom (na vrhu)
                if (_currentRoutePath != null &&
                    _currentInstructionIndex <
                        _currentRoutePath!.instructions.length)
                  Positioned(
                    top: 16,
                    left: 16,
                    right: 16,
                    child: CurrentInstructionBanner(
                      instruction: _currentRoutePath!
                          .instructions[_currentInstructionIndex],
                      nextInstruction:
                          _currentInstructionIndex + 1 <
                              _currentRoutePath!.instructions.length
                          ? _currentRoutePath!
                                .instructions[_currentInstructionIndex + 1]
                          : null,
                    ),
                  ),

                // Panel sa informacijama o poziciji
                Positioned(
                  top: _currentRoutePath != null ? 160 : 16,
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
                        // 📍 SNAP-TO-ROAD indikator
                        if (_snappedPosition != null)
                          const Text(
                            '📌 Snap: ON',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
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

                // Navigation Instructions Panel (na dnu ekrana)
                if (_currentRoutePath != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: NavigationInstructionsPanel(
                      routePath: _currentRoutePath!,
                      currentInstructionIndex: _currentInstructionIndex,
                      onClose: _clearRoute,
                    ),
                  ),
              ],
            ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Dugme za brisanje rute
          if (_routePoints.isNotEmpty)
            FloatingActionButton.extended(
              heroTag: 'clear_route',
              onPressed: _clearRoute,
              backgroundColor: Colors.red,
              icon: const Icon(Icons.clear),
              label: const Text('Obriši'),
            ),

          // Loading indicator
          if (_isLoadingRoute)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: CircularProgressIndicator(),
            ),

          const SizedBox(height: 12),

          // Promena stila mape
          FloatingActionButton(
            heroTag: 'map_style',
            mini: true,
            onPressed: _changeMapStyle,
            backgroundColor: Colors.green[600],
            child: const Icon(Icons.layers, color: Colors.white),
          ),

          const SizedBox(height: 12),

          // 3D toggle
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

          // Center on user location
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
