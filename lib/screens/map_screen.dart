import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Za rootBundle (učitavanje assets)
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

  List<LatLng> _routePoints = [];
  LatLng? _destination;
  bool _isLoadingRoute = false;
  bool _isRerouting = false;
  bool _isLoading = true;
  bool _is3DMode = true; // 🎮 Podrazumevano 3D (kao u Android navigation)
  bool _isAutoFollowing = false; // 🎯 Isključen auto-follow - samo na klik
  bool _isProgrammaticCameraMove =
      false; // 🎯 Flag za razlikovanje user vs programmatic camera moves
  int _currentMapStyleIndex = 0;

  Line? _routeLine;
  Line?
  _routeShieldLine; // 📍 Shield layer (obrub oko rute) - kao u Android verziji
  Symbol? _destinationSymbol;
  Circle?
  _userLocationCircle; // 📍 SNAP-TO-ROAD: Custom location marker (kao LocationComponent)
  Circle? _userLocationPulse; // 📍 Pulsing circle oko markera za vidljivost
  Path? _currentRoutePath;

  // 🎯 DVA ODVOJENA SISTEMA:
  // 1. Za KAMERU - prati SVE instrukcije (uključujući sign=0)
  int _currentInstructionIndex = 1; // Za heading i rotaciju kamere

  // 2. Za UI PRIKAZ - samo prave akcije (bez sign=0 "Continue")
  List<Instruction> _filteredInstructions = [];
  int _currentFilteredIndex = 0; // Index u filtriranoj listi za UI

  static const double _navigationZoomLevel = 18.0; // 🔍 Bliži zoom nivo
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
      _isLoading = false;
    });

    _startLocationTracking();
  }

  void _startLocationTracking() {
    _locationService.startTracking();
    _locationService.positionStream.listen((Position position) {
      setState(() {
        _currentPosition = position;

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
  /// Identično Android LocationComponent sa RenderMode.GPS + Bearing Indicator
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

      // 1. Accuracy circle (PLAVI - kao u Android verziji: maplibre_location_layer_blue)
      _userLocationPulse = await _mapController!.addCircle(
        CircleOptions(
          geometry: markerPosition,
          circleRadius: 18.0, // Accuracy radius
          circleColor:
              '#56A8FB', // Plava boja iz Android navigation (route layer blue)
          circleOpacity: 0.15, // Ista alpha kao u Android styles.xml
          circleStrokeWidth: 0.0,
        ),
      );

      // 2. PLAVI Location Marker u centru (kao Android maplibre_user_icon)
      _userLocationCircle = await _mapController!.addCircle(
        CircleOptions(
          geometry: markerPosition,
          circleRadius: 8.0, // Veći radius za bolju vidljivost
          circleColor: '#56A8FB', // Plava navigation boja
          circleOpacity: 1.0,
          circleStrokeWidth: 3.0,
          circleStrokeColor: '#FFFFFF', // Beli border
          circleStrokeOpacity: 1.0,
        ),
      );

      // 📍 Bearing indicator uklonjen - nije potreban, dovoljno je samo plavi pin
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

    // 🧭 ROTACIJA KAMERE - kamera gleda OD tvoje pozicije KA SLEDEĆOJ tački na ruti
    // Kao da stoji IZA tebe i gleda NAPRED prema sledecom delu puta
    double cameraBearing = 0.0;

    if (_routePoints.isNotEmpty) {
      // Nađi sledeću tačku na ruti ISPRED trenutne pozicije
      cameraBearing = _calculateBearingToNextRoutePoint();
    }

    // 🎯 Označi da je ovo programmatic move
    _isProgrammaticCameraMove = true;

    await _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: targetPosition,
          zoom: _navigationZoomLevel,
          bearing:
              cameraBearing, // 🧭 Rotira prema heading-u trenutne instrukcije
          tilt: _is3DMode ? _tiltAngle : 0.0,
        ),
      ),
    );
  }

  /// 🧭 Izračunava bearing OD trenutne pozicije KA sledećoj tački na ruti
  /// Kamera "stoji iza tebe" i gleda napred prema putu
  double _calculateBearingToNextRoutePoint() {
    if (_currentPosition == null || _routePoints.isEmpty) return 0.0;

    final currentPos =
        _snappedPosition ??
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

    // Nađi najbližu tačku na ruti ISPRED trenutne pozicije
    LatLng? nextPoint;
    double minDistance = double.infinity;
    int closestIndex = 0;

    // Prvo nađi najbližu tačku
    for (int i = 0; i < _routePoints.length; i++) {
      final distance = _routingService.calculateDistance(
        currentPos.latitude,
        currentPos.longitude,
        _routePoints[i].latitude,
        _routePoints[i].longitude,
      );

      if (distance < minDistance) {
        minDistance = distance;
        closestIndex = i;
      }
    }

    // 🎯 Nađi tačku ~30 metara ISPRED za smooth kameru rotaciju
    // Ovo daje stabilnu rotaciju kao u Google Maps
    double accumulatedDistance = 0.0;
    int lookAheadIndex = closestIndex;

    for (int i = closestIndex; i < _routePoints.length - 1; i++) {
      final segmentDistance = _routingService.calculateDistance(
        _routePoints[i].latitude,
        _routePoints[i].longitude,
        _routePoints[i + 1].latitude,
        _routePoints[i + 1].longitude,
      );

      accumulatedDistance += segmentDistance;
      lookAheadIndex = i + 1;

      // Pronađi tačku ~30m ispred
      if (accumulatedDistance >= 30.0) break;
    }

    nextPoint = _routePoints[lookAheadIndex];

    // Izračunaj bearing OD trenutne pozicije KA toj tački
    return _calculateBearing(
      currentPos.latitude,
      currentPos.longitude,
      nextPoint.latitude,
      nextPoint.longitude,
    );
  }

  /// Pomoćna funkcija za računanje bearing-a između dve tačke (koristi dart:math)
  double _calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    // Konvertuj u radijane
    final lat1Rad = lat1 * math.pi / 180.0;
    final lat2Rad = lat2 * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;

    // Haversine formula za bearing
    final y = math.sin(dLon) * math.cos(lat2Rad);
    final x =
        math.cos(lat1Rad) * math.sin(lat2Rad) -
        math.sin(lat1Rad) * math.cos(lat2Rad) * math.cos(dLon);

    final bearing = math.atan2(y, x);

    // Konvertuj u stepene (0-360)
    return (bearing * 180.0 / math.pi + 360) % 360;
  }

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
    setState(() {
      _is3DMode = !_is3DMode;
      _isAutoFollowing = false; // 🎯 Isključi autofokus kad se menja prikaz
    });
    _centerMapOnUser();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_is3DMode ? '🎮 3D Pogled' : '📱 2D Mapa'),
        duration: const Duration(seconds: 1),
        backgroundColor: _is3DMode ? Colors.blue : Colors.grey,
        behavior: SnackBarBehavior.fixed,
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

        // Resetuj reference na markere jer setStyle() briše sve
        _userLocationCircle = null;
        _userLocationPulse = null;
        _routeLine = null;
        _routeShieldLine = null;
        _destinationSymbol = null;

        // Sačekaj malo da se stil učita
        await Future.delayed(const Duration(milliseconds: 500));

        // 📍 PRIORITET: Prvo nacrtaj location marker (da se ne izgubi!)
        await _updateUserLocationMarker();

        // Zatim nacrtaj rutu ako postoji
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
          // 🎯 FILTRIRAJ instrukcije - ukloni sve "Continue" (sign=0)
          final allInstructions = response.paths.first.instructions;
          final filtered = <Instruction>[];

          for (var instr in allInstructions) {
            // Preskoči "Continue" instrukcije (sign = 0)
            if (instr.sign != 0) {
              filtered.add(instr);
            }
          }

          setState(() {
            _currentRoutePath = response.paths.first;
            _routePoints = routePoints;
            _destination = destination;
            _isLoadingRoute = false;
            _currentInstructionIndex =
                1; // Počinjemo od druge instrukcije (index 1)

            // 🎯 Setuj filtriranu listu i startuj od prve PRAVE akcije
            _filteredInstructions = filtered;
            _currentFilteredIndex = 0;

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

          // 🎯 Pozicioniraj kameru JEDNOM kada ruta krene, ali ne aktiviraj auto-follow
          Future.delayed(const Duration(seconds: 2), () {
            _centerMapOnUser(); // Samo centraj jednom
            // _isAutoFollowing ostaje false - korisnik može slobodno da se kreće
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

    // Obriši stare linije
    if (_routeLine != null) {
      await _mapController!.removeLine(_routeLine!);
    }
    if (_routeShieldLine != null) {
      await _mapController!.removeLine(_routeShieldLine!);
    }

    // 1. Shield Layer (obrub oko rute) - tamnija i deblja linija ispod glavne
    // Identično Android MapRouteLayerProvider shield layer
    _routeShieldLine = await _mapController!.addLine(
      LineOptions(
        geometry: _routePoints,
        lineColor: '#2F7AC6', // Shield color iz Android navigation
        lineWidth: 10.0, // Deblja od glavne linije
        lineOpacity: 0.7,
        lineJoin: 'round',
      ),
    );

    // 2. Glavna Route Layer (svetlo plava)
    // Boja i stil iz Android NavigationMapRoute
    _routeLine = await _mapController!.addLine(
      LineOptions(
        geometry: _routePoints,
        lineColor: '#56A8FB', // Route layer blue iz Android navigation
        lineWidth: 7.0, // Optimalna debljina za navigation
        lineOpacity: 0.95,
        lineJoin: 'round', // Rounded line join kao u Android
      ),
    );
  }

  Future<void> _addDestinationMarker() async {
    if (_mapController == null || _destination == null) return;

    if (_destinationSymbol != null) {
      await _mapController!.removeSymbol(_destinationSymbol!);
    }

    // 📍 Koristimo map_marker_dark.png iz Android navigation UI
    // (navigationViewDestinationMarker iz styles.xml)
    try {
      // Pokušaj da dodaš custom marker sliku
      await _mapController!.addImage(
        'destination-marker',
        (await rootBundle.load(
          'assets/icons/map_marker_dark.png',
        )).buffer.asUint8List(),
      );

      _destinationSymbol = await _mapController!.addSymbol(
        SymbolOptions(
          geometry: _destination!,
          iconImage: 'destination-marker',
          iconSize: 1.5, // Odgovarajuća veličina
          iconAnchor: 'bottom', // Sidri marker na dnu (pin stil)
        ),
      );
    } catch (e) {
      // Fallback na standardni marker ako slika ne uspe
      _destinationSymbol = await _mapController!.addSymbol(
        SymbolOptions(
          geometry: _destination!,
          iconImage: 'marker-15',
          iconSize: 2.5,
          iconColor: '#E93340', // Crvena iz Android navigation (congestion red)
        ),
      );
    }
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

    // 🎯 Označi da je ovo programmatic move
    _isProgrammaticCameraMove = true;

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
    if (_routeShieldLine != null && _mapController != null) {
      await _mapController!.removeLine(_routeShieldLine!);
    }
    if (_destinationSymbol != null && _mapController != null) {
      await _mapController!.removeSymbol(_destinationSymbol!);
    }

    setState(() {
      _routePoints = [];
      _destination = null;
      _routeLine = null;
      _routeShieldLine = null;
      _destinationSymbol = null;
      _currentRoutePath = null;
      _currentInstructionIndex = 1;
      _filteredInstructions = []; // 🎯 Reset filtrirane instrukcije
      _currentFilteredIndex = 0;
      _snappedPosition = null; // 📍 SNAP-TO-ROAD: Reset snapped pozicije
    });

    // 📍 SNAP-TO-ROAD: Ažuriraj marker na raw GPS poziciju
    await _updateUserLocationMarker();
    _centerMapOnUser();
    _showSuccess('Ruta obrisana');
  }

  /// Proverava napredak prema sledećoj PRAOJ akciji (iz filtrirane liste)
  void _checkInstructionProgress() {
    if (_currentRoutePath == null || _currentPosition == null) return;
    if (_routePoints.isEmpty || _filteredInstructions.isEmpty) return;

    // Preskačemo ako smo prošli sve filtrirane instrukcije
    if (_currentFilteredIndex >= _filteredInstructions.length) return;

    final currentFilteredInstruction =
        _filteredInstructions[_currentFilteredIndex];

    // Dobijamo tačku na ruti gde se nalazi ova instrukcija
    final instructionPointIndex = currentFilteredInstruction.interval.first;

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

      // Ako smo prošli instrukciju (manje od 15m), prelazimo na sledeću PRAVU akciju
      if (distanceToInstruction < 15.0) {
        setState(() {
          _currentFilteredIndex++;
        });

        // Prikaži sledeću PRAVU akciju
        if (_currentFilteredIndex < _filteredInstructions.length) {
          _showCurrentInstruction();
        } else {
          _showSuccess('🏁 Stigli ste na destinaciju!');
        }
      }
    }
  }

  /// Prikazuje sledeću PRAVU akciju (iz filtrirane liste)
  void _showCurrentInstruction() {
    // 🎯 Koristi filtriranu listu - prikazuj samo prave akcije
    if (_filteredInstructions.isEmpty) return;
    if (_currentFilteredIndex >= _filteredInstructions.length) {
      // Stigli smo do kraja - prikaži "Arrive"
      return;
    }

    final instruction = _filteredInstructions[_currentFilteredIndex];

    // Izračunaj preostalu distancu do ove instrukcije u realnom vremenu
    double remainingDistance = instruction.distance;

    if (_currentPosition != null && _routePoints.isNotEmpty) {
      // Pronađi tačku u ruti gde počinje ova instrukcija
      final instructionPointIndex = instruction.interval.first;

      if (instructionPointIndex < _routePoints.length) {
        final instructionPoint = _routePoints[instructionPointIndex];

        final fromPosition =
            _snappedPosition ??
            LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

        remainingDistance = _routingService.calculateDistance(
          fromPosition.latitude,
          fromPosition.longitude,
          instructionPoint.latitude,
          instructionPoint.longitude,
        );
      }
    }

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
                  Text(
                    'Za ${remainingDistance.round()} m',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 4),
        backgroundColor: Colors.blue[800],
        behavior: SnackBarBehavior.fixed,
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
          // 🎯 FILTRIRAJ instrukcije za re-routing
          final allInstructions = response.paths.first.instructions;
          final filtered = <Instruction>[];

          for (var instr in allInstructions) {
            if (instr.sign != 0) {
              filtered.add(instr);
            }
          }

          setState(() {
            _currentRoutePath = response.paths.first;
            _routePoints = routePoints;
            _isRerouting = false;
            _currentInstructionIndex =
                1; // Reset na drugu instrukciju posle reroutinga

            // 🎯 Reset filtrirane instrukcije
            _filteredInstructions = filtered;
            _currentFilteredIndex = 0;

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
              behavior: SnackBarBehavior.fixed,
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
      SnackBar(
        content: Text('❌ $message'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.fixed, // Fixed na dnu, iznad panela
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ $message'),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.fixed, // Fixed na dnu, iznad panela
        duration: const Duration(seconds: 2),
      ),
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
                  onCameraIdle: () {
                    // 🎯 Isključi auto-follow samo ako je korisnik ručno pomerio mapu
                    if (_isProgrammaticCameraMove) {
                      // Ovo je bio programmatic move, samo resetuj flag
                      _isProgrammaticCameraMove = false;
                    } else {
                      // Ovo je bio user-initiated move, isključi auto-follow
                      if (_isAutoFollowing) {
                        setState(() => _isAutoFollowing = false);
                      }
                    }
                  },
                  // 📍 SNAP-TO-ROAD: Isključena built-in strelica, koristimo samo custom marker
                  myLocationEnabled: false,
                  compassEnabled: true,
                  minMaxZoomPreference: const MinMaxZoomPreference(5.0, 20.0),
                ),

                // Veliki banner sa trenutnom PRAVOM akcijom (na vrhu)
                if (_filteredInstructions.isNotEmpty &&
                    _currentFilteredIndex < _filteredInstructions.length)
                  Positioned(
                    top: 16,
                    left: 16,
                    right: 16,
                    child: CurrentInstructionBanner(
                      instruction: _filteredInstructions[_currentFilteredIndex],
                      nextInstruction:
                          _currentFilteredIndex + 1 <
                              _filteredInstructions.length
                          ? _filteredInstructions[_currentFilteredIndex + 1]
                          : null,
                    ),
                  ),

                // Panel sa brzinom i snap indikatorom
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
                        // Brzina u km/h
                        Text(
                          '🚗 ${_currentPosition?.speed != null ? ((_currentPosition!.speed * 3.6).toStringAsFixed(0)) : "0"} km/h',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
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
