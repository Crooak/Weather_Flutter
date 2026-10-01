import 'package:flutter/material.dart';
import 'screens/weather_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SamsungWeatherApp());
}

class SamsungWeatherApp extends StatelessWidget {
  const SamsungWeatherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'One UI Weather',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark, // Темная тема подчеркивает стеклянный эффект
        fontFamily: 'Roboto', // Или фирменный шрифт SamsungOne, если добавите
      ),
      home: const WeatherScreen(),
    );
  }
}
