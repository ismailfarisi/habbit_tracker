import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A city for picking prayer times without location permission.
class City {
  final String name;
  final String country;
  final double lat, lng;
  final String calcMethod;
  const City(this.name, this.country, this.lat, this.lng, this.calcMethod);
}

const cities = [
  City('Dubai', 'UAE', 25.2048, 55.2708, 'dubai'),
  City('Abu Dhabi', 'UAE', 24.4539, 54.3773, 'dubai'),
  City('Sharjah', 'UAE', 25.3463, 55.4209, 'dubai'),
  City('Ajman', 'UAE', 25.4052, 55.5136, 'dubai'),
  City('Al Ain', 'UAE', 24.2075, 55.7447, 'dubai'),
  City('Ras Al Khaimah', 'UAE', 25.8007, 55.9762, 'dubai'),
  City('Fujairah', 'UAE', 25.1288, 56.3265, 'dubai'),
  City('Riyadh', 'Saudi Arabia', 24.7136, 46.6753, 'umm_al_qura'),
  City('Jeddah', 'Saudi Arabia', 21.4858, 39.1925, 'umm_al_qura'),
  City('Makkah', 'Saudi Arabia', 21.3891, 39.8579, 'umm_al_qura'),
  City('Madinah', 'Saudi Arabia', 24.5247, 39.5692, 'umm_al_qura'),
  City('Doha', 'Qatar', 25.2854, 51.5310, 'qatar'),
  City('Kuwait City', 'Kuwait', 29.3759, 47.9774, 'kuwait'),
  City('Manama', 'Bahrain', 26.2235, 50.5876, 'dubai'),
  City('Muscat', 'Oman', 23.5880, 58.3829, 'dubai'),
  City('Cairo', 'Egypt', 30.0444, 31.2357, 'egyptian'),
  City('Istanbul', 'Turkey', 41.0082, 28.9784, 'turkey'),
  City('Tehran', 'Iran', 35.6892, 51.3890, 'tehran'),
  City('Karachi', 'Pakistan', 24.8607, 67.0011, 'karachi'),
  City('Lahore', 'Pakistan', 31.5204, 74.3587, 'karachi'),
  City('Delhi', 'India', 28.6139, 77.2090, 'karachi'),
  City('Mumbai', 'India', 19.0760, 72.8777, 'karachi'),
  City('Kozhikode', 'India', 11.2588, 75.7804, 'karachi'),
  City('Hyderabad', 'India', 17.3850, 78.4867, 'karachi'),
  City('Dhaka', 'Bangladesh', 23.8103, 90.4125, 'karachi'),
  City('Kuala Lumpur', 'Malaysia', 3.1390, 101.6869, 'singapore'),
  City('Singapore', 'Singapore', 1.3521, 103.8198, 'singapore'),
  City('Jakarta', 'Indonesia', -6.2088, 106.8456, 'singapore'),
  City('London', 'UK', 51.5074, -0.1278, 'muslim_world_league'),
  City('Paris', 'France', 48.8566, 2.3522, 'muslim_world_league'),
  City('Berlin', 'Germany', 52.5200, 13.4050, 'muslim_world_league'),
  City('New York', 'USA', 40.7128, -74.0060, 'north_america'),
  City('Toronto', 'Canada', 43.6532, -79.3832, 'north_america'),
  City('Sydney', 'Australia', -33.8688, 151.2093, 'muslim_world_league'),
];

/// Battery-optimisation guidance for phone makers known to stop reminders.
const batteryTips = {
  'Xiaomi / Redmi / POCO':
      'Settings › Apps › Daily Discipline › Battery saver › No restrictions. Also turn on Autostart for the app.',
  'Samsung':
      'Settings › Apps › Daily Discipline › Battery › Unrestricted. Then make sure it is not in Battery › Background usage limits › Sleeping apps.',
  'Huawei / Honor':
      'Settings › Battery › App launch › Daily Discipline: turn off "Manage automatically" and allow Auto-launch, Secondary launch and Run in background.',
};

Future<City?> pickPrayerCity(
  BuildContext context,
) => showModalBottomSheet<City>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (c) {
    var query = '';
    return StatefulBuilder(
      builder: (c, setState) {
        final matches = cities.where(
          (city) =>
              '${city.name} ${city.country}'.toLowerCase().contains(query),
        );
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              MediaQuery.viewInsetsOf(c).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  decoration: const InputDecoration(labelText: 'Search city'),
                  onChanged: (s) =>
                      setState(() => query = s.trim().toLowerCase()),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final city in matches)
                        ListTile(
                          title: Text(city.name),
                          subtitle: Text(city.country),
                          onTap: () => Navigator.pop(c, city),
                        ),
                      if (matches.isEmpty)
                        const ListTile(
                          title: Text(
                            'Enter your coordinates on the Prayer times page.',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  },
);

class BatteryTips extends StatelessWidget {
  const BatteryTips({super.key});
  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android)
      return const SizedBox.shrink();
    return ExpansionTile(
      title: const Text('If reminders are silent'),
      children: [
        for (final tip in batteryTips.entries)
          ListTile(title: Text(tip.key), subtitle: Text(tip.value)),
        TextButton(
          onPressed: () async {
            try {
              await AppSettings.openAppSettings(
                type: AppSettingsType.batteryOptimization,
              );
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Open your phone’s battery settings to change this.',
                    ),
                  ),
                );
              }
            }
          },
          child: const Text('Open battery settings'),
        ),
      ],
    );
  }
}
