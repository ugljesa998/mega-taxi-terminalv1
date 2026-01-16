class GraphHopperResponse {
  final List<Path> paths;
  final Info info;

  GraphHopperResponse({required this.paths, required this.info});

  factory GraphHopperResponse.fromJson(Map<String, dynamic> json) {
    return GraphHopperResponse(
      paths: (json['paths'] as List)
          .map((path) => Path.fromJson(path))
          .toList(),
      info: Info.fromJson(json['info']),
    );
  }
}

class Path {
  final double distance;
  final double time;
  final String points;
  final bool pointsEncoded;
  final double pointsEncodedMultiplier;
  final List<Instruction> instructions;
  final List<double> bbox;

  Path({
    required this.distance,
    required this.time,
    required this.points,
    required this.pointsEncoded,
    required this.pointsEncodedMultiplier,
    required this.instructions,
    required this.bbox,
  });

  factory Path.fromJson(Map<String, dynamic> json) {
    return Path(
      distance: (json['distance'] as num).toDouble(),
      time: (json['time'] as num).toDouble(),
      points: json['points'] as String,
      pointsEncoded: json['points_encoded'] ?? true,
      pointsEncodedMultiplier:
          (json['points_encoded_multiplier'] as num?)?.toDouble() ?? 100000.0,
      instructions:
          (json['instructions'] as List?)
              ?.map((instruction) => Instruction.fromJson(instruction))
              .toList() ??
          [],
      bbox:
          (json['bbox'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
          [],
    );
  }

  String getDistanceText() {
    if (distance < 1000) {
      return '${distance.toStringAsFixed(0)} m';
    }
    return '${(distance / 1000).toStringAsFixed(1)} km';
  }

  String getTimeText() {
    final minutes = (time / 60000).round();
    if (minutes < 60) {
      return '$minutes min';
    }
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    return '$hours h $remainingMinutes min';
  }
}

class Instruction {
  final double distance;
  final double time;
  final int sign;
  final String text;
  final String streetName;
  final List<int> interval;
  final int? exitNumber;
  final double?
  heading; // 🧭 Heading za rotaciju kamere (kod sign=0 instrukcija)

  Instruction({
    required this.distance,
    required this.time,
    required this.sign,
    required this.text,
    required this.streetName,
    required this.interval,
    this.exitNumber,
    this.heading, // Opciono - samo sign=0 instrukcije imaju heading
  });

  factory Instruction.fromJson(Map<String, dynamic> json) {
    return Instruction(
      distance: (json['distance'] as num).toDouble(),
      time: (json['time'] as num).toDouble(),
      sign: json['sign'] as int,
      text: json['text'] as String,
      streetName: json['street_name'] as String? ?? '',
      interval: (json['interval'] as List).map((e) => e as int).toList(),
      exitNumber: json['exit_number'] as int?,
      heading: json['heading'] != null
          ? (json['heading'] as num).toDouble()
          : null,
    );
  }

  String getDistanceText() {
    if (distance < 1000) {
      return '${distance.toStringAsFixed(0)} m';
    }
    return '${(distance / 1000).toStringAsFixed(1)} km';
  }

  String getInstructionIcon() {
    switch (sign) {
      case -98: // U-turn left
        return '↶';
      case -8: // U-turn right
        return '↷';
      case -7: // Keep left
        return '⬅️';
      case -3: // Sharp left
        return '⬅️';
      case -2: // Left
        return '⬅️';
      case -1: // Slight left
        return '↖️';
      case 0: // Continue straight
        return '⬆️';
      case 1: // Slight right
        return '↗️';
      case 2: // Right
        return '➡️';
      case 3: // Sharp right
        return '➡️';
      case 4: // Finish
        return '🏁';
      case 5: // Via reached
        return '📍';
      case 6: // Roundabout
        return '🔄';
      case 7: // Keep right
        return '➡️';
      default:
        return '⬆️';
    }
  }
}

class Info {
  final List<String> copyrights;
  final int took;
  final String roadDataTimestamp;

  Info({
    required this.copyrights,
    required this.took,
    required this.roadDataTimestamp,
  });

  factory Info.fromJson(Map<String, dynamic> json) {
    return Info(
      copyrights: (json['copyrights'] as List).map((e) => e as String).toList(),
      took: json['took'] as int,
      roadDataTimestamp: json['road_data_timestamp'] as String,
    );
  }
}
