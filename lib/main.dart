import 'package:flutter/material.dart';
import 'screens/map_screen.dart';

void main() {
  runApp(const MegaTaxiTerminalApp());
}

class MegaTaxiTerminalApp extends StatelessWidget {
  const MegaTaxiTerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mega Taxi Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}
