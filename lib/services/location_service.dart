import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

class LocationService {
  StreamSubscription<Position>? _positionSubscription;
  final _positionController = StreamController<Position>.broadcast();

  /// Stream koji emituje pozicije
  Stream<Position> get positionStream => _positionController.stream;

  /// Trenutna pozicija (cache)
  Position? _currentPosition;
  Position? get currentPosition => _currentPosition;

  /// Da li je tracking aktivan
  bool get isTracking => _positionSubscription != null;

  /// Provera i traženje permisija
  Future<bool> requestPermissions() async {
    print('🔐 Proveravam GPS permisije...');

    // Provera da li je Location servis uključen
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      print('❌ GPS nije uključen na telefonu');
      return false;
    }

    // Traženje permisije
    var permission = await Permission.locationWhenInUse.status;

    if (permission.isDenied) {
      permission = await Permission.locationWhenInUse.request();
    }

    if (permission.isPermanentlyDenied) {
      print('❌ Permisija trajno odbijena - otvori Settings');
      await openAppSettings();
      return false;
    }

    if (permission.isGranted) {
      print('✅ GPS permisije odobrene');
      return true;
    }

    print('❌ GPS permisije odbijene');
    return false;
  }

  /// Pokreće praćenje GPS pozicije
  Future<void> startTracking() async {
    if (isTracking) {
      print('⚠️ Tracking je već pokrenut');
      return;
    }

    print('📡 Pokrećem praćenje pozicije...');

    // NAVIGACIJA - najbolja konfiguracija za smooth tracking
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation, // Najbolja preciznost
      distanceFilter: 1, // Update na svakom metru - smooth kao Mapbox
    );

    _positionSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) {
            _currentPosition = position;
            _positionController.add(position);

            // Debug log (ukloni kasnije za production)
            print(
              '📍 Pozicija: ${position.latitude}, ${position.longitude} | '
              'Heading: ${position.heading}° | '
              'Speed: ${position.speed.toStringAsFixed(1)} m/s',
            );
          },
          onError: (error) {
            print('❌ Greška pri praćenju pozicije: $error');
          },
        );

    print('✅ Tracking pokrenut!');
  }

  /// Zaustavlja praćenje
  void stopTracking() {
    print('🛑 Zaustavljam tracking...');
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  /// Dobija trenutnu poziciju (jednokratno)
  Future<Position?> getCurrentPosition() async {
    try {
      print('📍 Dobijam trenutnu poziciju...');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _currentPosition = position;
      return position;
    } catch (e) {
      print('❌ Greška pri dobijanju pozicije: $e');
      return null;
    }
  }

  /// Cleanup
  void dispose() {
    print('🧹 LocationService cleanup...');
    stopTracking();
    _positionController.close();
  }
}
