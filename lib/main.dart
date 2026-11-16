import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';

import 'package:package_info_plus/package_info_plus.dart';

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Мой график',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ru', 'RU')],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData && snapshot.data != null) {
          return const ShiftCalendar();
        }
        return const LoginScreen();
      },
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      final GoogleSignIn signIn = GoogleSignIn.instance;
      await signIn.initialize();
      final GoogleSignInAccount googleUser = await signIn.authenticate();
      final GoogleSignInAuthentication googleAuth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка входа: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.calendar_month, size: 80, color: Colors.blue),
              const SizedBox(height: 24),
              const Text(
                'Мой график смен',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 48),
              if (_isLoading)
                const CircularProgressIndicator()
              else
                ElevatedButton.icon(
                  onPressed: _signInWithGoogle,
                  icon: const Icon(Icons.login),
                  label: const Text('Войти через Google'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    textStyle: const TextStyle(fontSize: 16),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class ShiftEvent {
  final DateTime date;
  final String title;
  final Color color;
  final TimeOfDay? startTime;
  final TimeOfDay? endTime;
  final int? reminderMinutes;

  ShiftEvent({
    required this.date,
    required this.title,
    required this.color,
    this.startTime,
    this.endTime,
    this.reminderMinutes,
  });

  Map<String, dynamic> toMap() {
    return {
      'date': date.toIso8601String(),
      'title': title,
      'color': color.toARGB32(),
      'start_hour': startTime?.hour,
      'start_minute': startTime?.minute,
      'end_hour': endTime?.hour,
      'end_minute': endTime?.minute,
      'reminder_minutes': reminderMinutes,
    };
  }

  factory ShiftEvent.fromMap(Map<String, dynamic> map) {
    return ShiftEvent(
      date: DateTime.parse(map['date']),
      title: map['title'],
      color: Color(map['color']),
      startTime: map['start_hour'] != null
          ? TimeOfDay(hour: map['start_hour'], minute: map['start_minute'])
          : null,
      endTime: map['end_hour'] != null
          ? TimeOfDay(hour: map['end_hour'], minute: map['end_minute'])
          : null,
      reminderMinutes: map['reminder_minutes'],
    );
  }
}

class ShiftCalendar extends StatefulWidget {
  const ShiftCalendar({super.key});

  @override
  State<ShiftCalendar> createState() => _ShiftCalendarState();
}

class _ShiftCalendarState extends State<ShiftCalendar> {
  DateTime _currentMonth = DateTime.now();
  DateTime? _startDate;
  late final PageController _pageController;
  final List<ShiftEvent> _events = [];

  double _hourlyRate = 0.0;
  double _shiftHours = 12.0;
  TimeOfDay _shiftStartTime = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _shiftEndTime = const TimeOfDay(hour: 21, minute: 0);
  TimeOfDay _weekdayStart = const TimeOfDay(hour: 7, minute: 30);
  TimeOfDay _weekdayEnd = const TimeOfDay(hour: 21, minute: 0);
  TimeOfDay _weekendStart = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _weekendEnd = const TimeOfDay(hour: 22, minute: 0);
  int _notifyHoursBefore = 12;
  int _notifyMinutesBefore = 0;
  bool _notificationsEnabled = true;
  bool _isStatsExpanded = false;
  bool _isLoading = true;
  String _appVersion = '';
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _notificationsInitialized = false;
  String? _updateUrl;
  String? _updateVersion;

  final User? _user = FirebaseAuth.instance.currentUser;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  final List<String> _months = [
    'январь',
    'февраль',
    'март',
    'апрель',
    'май',
    'июнь',
    'июль',
    'август',
    'сентябрь',
    'октябрь',
    'ноябрь',
    'декабрь',
  ];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _pageController = PageController(
      initialPage: (now.year - 2026) * 12 + now.month - 1,
    );
    _loadVersion();
    _checkForUpdates();
    _initNotifications();
    _loadFromCloud();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _appVersion = '${info.version}.${info.buildNumber}';
    });
  }

  Future<void> _initNotifications() async {
    try {
      final timeZoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation(timeZoneInfo.identifier));

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const InitializationSettings settings = InitializationSettings(
        android: androidSettings,
      );

      await _notifications.initialize(settings: settings);

      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestExactAlarmsPermission();

      _notificationsInitialized = true;
    } catch (e) {
      debugPrint('Ошибка инициализации уведомлений: $e');
    }
  }

  Future<void> _checkForUpdates() async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://api.github.com/repos/ak3301389/grafsmen/releases/latest',
        ),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String tagName = data['tag_name'] ?? '';
        final String releaseVersion = tagName.replaceAll('v', '');

        final info = await PackageInfo.fromPlatform();
        final String currentVersion = '${info.version}.${info.buildNumber}';

        if (_isNewerVersion(releaseVersion, currentVersion)) {
          final assets = data['assets'] as List<dynamic>;
          final apkAsset = assets.firstWhere(
            (a) => (a['name'] as String).endsWith('.apk'),
            orElse: () => null,
          );

          if (apkAsset != null) {
            setState(() {
              _updateUrl = apkAsset['browser_download_url'];
              _updateVersion = releaseVersion;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Ошибка проверки обновлений: $e');
    }
  }

  bool _isNewerVersion(String githubVersion, String currentVersion) {
    final gParts = githubVersion.split('.').map(int.tryParse).toList();
    final cParts = currentVersion.split('.').map(int.tryParse).toList();

    for (int i = 0; i < gParts.length; i++) {
      final g = gParts[i] ?? 0;
      final c = i < cParts.length ? (cParts[i] ?? 0) : 0;
      if (g > c) return true;
      if (g < c) return false;
    }
    return false;
  }

  Future<void> _loadFromCloud() async {
    if (_user == null) {
      setState(() => _isLoading = false);
      _scheduleNotifications();
      return;
    }
    try {
      final doc = await _db.collection('users').doc(_user!.uid).get();
      if (doc.exists) {
        final data = doc.data()!;
        setState(() {
          if (data['start_date'] != null) {
            _startDate = DateTime.parse(data['start_date']);
          }
          _hourlyRate = (data['hourly_rate'] ?? 0.0).toDouble();
          if (data['weekday_start_hour'] != null) {
            _weekdayStart = TimeOfDay(
              hour: data['weekday_start_hour'],
              minute: data['weekday_start_minute'] ?? 0,
            );
          }
          if (data['weekday_end_hour'] != null) {
            _weekdayEnd = TimeOfDay(
              hour: data['weekday_end_hour'],
              minute: data['weekday_end_minute'] ?? 0,
            );
          }
          if (data['weekend_start_hour'] != null) {
            _weekendStart = TimeOfDay(
              hour: data['weekend_start_hour'],
              minute: data['weekend_start_minute'] ?? 0,
            );
          }
          if (data['weekend_end_hour'] != null) {
            _weekendEnd = TimeOfDay(
              hour: data['weekend_end_hour'],
              minute: data['weekend_end_minute'] ?? 0,
            );
          }
          _notifyHoursBefore = data['notify_hours_before'] ?? 12;
          _notifyMinutesBefore = data['notify_minutes_before'] ?? 0;
          _notificationsEnabled = data['notifications_enabled'] ?? true;
          _shiftHours = (data['shift_hours'] ?? 12.0).toDouble();
          final eventsList = data['events'] as List<dynamic>? ?? [];
          _events.clear();
          for (var e in eventsList) {
            _events.add(ShiftEvent.fromMap(Map<String, dynamic>.from(e)));
          }
        });
      }
    } catch (e) {
      debugPrint('Ошибка загрузки из облака: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _scheduleNotifications() async {
    if (!_notificationsInitialized || !_notificationsEnabled) return;

    await _notifications.cancelAll();

    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final tomorrowDate = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);

    final tomorrowEvents = _events
        .where(
          (e) =>
              e.date.year == tomorrowDate.year &&
              e.date.month == tomorrowDate.month &&
              e.date.day == tomorrowDate.day,
        )
        .toList();

    final isWorkTomorrow = _isWorkDay(tomorrowDate) == true;

    if (tomorrowEvents.isEmpty && !isWorkTomorrow) return;

    String title = 'Напоминание на завтра';
    String body = '';

    if (isWorkTomorrow && tomorrowEvents.isNotEmpty) {
      body = 'Завтра рабочая смена и ${tomorrowEvents.length} событий.';
    } else if (isWorkTomorrow) {
      body = 'Завтра рабочая смена.';
    } else if (tomorrowEvents.isNotEmpty) {
      body = 'Завтра: ${tomorrowEvents.map((e) => e.title).join(', ')}.';
    }

    final now = DateTime.now();

    if (isWorkTomorrow) {
      final shiftStart = DateTime(
        tomorrowDate.year,
        tomorrowDate.month,
        tomorrowDate.day,
        _shiftStartTime.hour,
        _shiftStartTime.minute,
      );

      final scheduledTime = shiftStart.subtract(
        Duration(hours: _notifyHoursBefore, minutes: _notifyMinutesBefore),
      );

      if (scheduledTime.isAfter(now)) {
        await _notifications.zonedSchedule(
          id: 0,
          title: 'Напоминание о смене',
          body: 'Завтра рабочая смена.',
          scheduledDate: tz.TZDateTime.from(scheduledTime, tz.local),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'shift_reminder',
              'Напоминания о сменах',
              importance: Importance.max,
              priority: Priority.high,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    }

    int notificationId = 1;
    for (var event in tomorrowEvents) {
      if (event.reminderMinutes != null && event.startTime != null) {
        final eventTime = DateTime(
          tomorrowDate.year,
          tomorrowDate.month,
          tomorrowDate.day,
          event.startTime!.hour,
          event.startTime!.minute,
        );
        final eventReminderTime = eventTime.subtract(
          Duration(minutes: event.reminderMinutes!),
        );

        if (eventReminderTime.isAfter(now)) {
          await _notifications.zonedSchedule(
            id: notificationId,
            title: 'Событие: ${event.title}',
            body: 'Начало в ${event.startTime!.format(context)}',
            scheduledDate: tz.TZDateTime.from(eventReminderTime, tz.local),
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'event_reminder',
                'Напоминания о событиях',
                importance: Importance.max,
                priority: Priority.high,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          );
          notificationId++;
        }
      }
    }
  }

  Future<void> _saveToCloud() async {
    if (_user == null) return;
    try {
      await _db.collection('users').doc(_user!.uid).set({
        'start_date': _startDate?.toIso8601String(),
        'hourly_rate': _hourlyRate,
        'weekday_start_hour': _weekdayStart.hour,
        'weekday_start_minute': _weekdayStart.minute,
        'weekday_end_hour': _weekdayEnd.hour,
        'weekday_end_minute': _weekdayEnd.minute,
        'weekend_start_hour': _weekendStart.hour,
        'weekend_start_minute': _weekendStart.minute,
        'weekend_end_hour': _weekendEnd.hour,
        'weekend_end_minute': _weekendEnd.minute,
        'notify_hours_before': _notifyHoursBefore,
        'notify_minutes_before': _notifyMinutesBefore,
        'notifications_enabled': _notificationsEnabled,
        'shift_hours': _shiftHours,
        'events': _events.map((e) => e.toMap()).toList(),
      });
    } catch (e) {
      debugPrint('Ошибка сохранения в облако: $e');
    }
  }

  TimeOfDay _getShiftStartTime(DateTime date) {
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      return _weekendStart;
    }
    return _weekdayStart;
  }

  TimeOfDay _getShiftEndTime(DateTime date) {
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      return _weekendEnd;
    }
    return _weekdayEnd;
  }

  double _getShiftDurationForDate(DateTime date) {
    final start = _getShiftStartTime(date);
    final end = _getShiftEndTime(date);
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;
    return (endMinutes - startMinutes) / 60.0;
  }

  bool? _isWorkDay(DateTime date) {
    if (_startDate == null) return null;
    final d = DateTime(date.year, date.month, date.day);
    final start = DateTime(
      _startDate!.year,
      _startDate!.month,
      _startDate!.day,
    );
    if (d.isBefore(start)) return null;
    final diff = d.difference(start).inDays;
    final pos = ((diff % 6) + 6) % 6;
    return pos < 3;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_months[_currentMonth.month - 1]} ${_currentMonth.year}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.today),
            tooltip: 'Сегодня',
            onPressed: () {
              final now = DateTime.now();
              _pageController.jumpToPage(
                (now.year - 2026) * 12 + now.month - 1,
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Настройки',
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Выйти',
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF8BBD0), Color(0xFFB2EBF2), Color(0xFFFFF9C4)],
          ),
        ),
        child: Column(
          children: [
            if (_updateUrl != null)
              Container(
                width: double.infinity,
                color: Colors.orange.shade100,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.system_update, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Доступно обновление: v$_updateVersion'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final dir = await getTemporaryDirectory();
                        final filePath = '${dir.path}/update.apk';

                        try {
                          final dio = Dio();
                          await dio.download(
                            _updateUrl!,
                            filePath,
                            onReceiveProgress: (received, total) {
                              if (total != -1) {
                                final progress = (received / total * 100)
                                    .toInt();
                                _notifications.show(
                                  id: 999,
                                  title: 'Скачивание обновления',
                                  body: '$progress%',
                                  notificationDetails: NotificationDetails(
                                    android: AndroidNotificationDetails(
                                      'download_channel',
                                      'Скачивание обновлений',
                                      importance: Importance.low,
                                      priority: Priority.low,
                                      showProgress: true,
                                      maxProgress: 100,
                                      progress: progress,
                                      ongoing: true,
                                      autoCancel: false,
                                    ),
                                  ),
                                );
                              }
                            },
                          );

                          await _notifications.cancel(id: 999);
                          await OpenFilex.open(filePath);
                          SystemNavigator.pop();
                        } catch (e) {
                          await _notifications.cancel(id: 999);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Ошибка: $e')),
                            );
                          }
                        }
                      },
                      child: const Text('Обновить'),
                    ),
                  ],
                ),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Text('Пн'),
                  Text('Вт'),
                  Text('Ср'),
                  Text('Чт'),
                  Text('Пт'),
                  Text('Сб'),
                  Text('Вс'),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    _currentMonth = DateTime(2026, 1 + index, 1);
                  });
                },
                itemBuilder: (context, index) {
                  final monthDate = DateTime(2026, 1 + index, 1);
                  return _buildMonth(monthDate);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ElevatedButton(
                onPressed: () => _addEventDialog(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.85),
                  foregroundColor: Colors.blue.shade900,
                  elevation: 0,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Добавить событие',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
            _buildStats(),
          ],
        ),
      ),
    );
  }

  Widget _buildMonth(DateTime date) {
    final firstDay = DateTime(date.year, date.month, 1);
    final daysInMonth = DateTime(date.year, date.month + 1, 0).day;
    final startWeekday = firstDay.weekday - 1;
    final emptyDays = List.generate(startWeekday, (_) => const SizedBox());

    final days = List.generate(daysInMonth, (i) {
      final dayDate = DateTime(date.year, date.month, i + 1);
      final isWork = _isWorkDay(dayDate);
      final isToday =
          dayDate.year == DateTime.now().year &&
          dayDate.month == DateTime.now().month &&
          dayDate.day == DateTime.now().day;
      final isPast = dayDate.isBefore(
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
      );

      final dayEvents = _events
          .where(
            (e) =>
                e.date.year == dayDate.year &&
                e.date.month == dayDate.month &&
                e.date.day == dayDate.day,
          )
          .toList();

      Color bgColor;
      Color textColor;
      String? label;

      if (isWork == null) {
        bgColor = Colors.grey.shade100;
        textColor = Colors.grey.shade400;
        label = null;
      } else if (isWork) {
        bgColor = isPast ? Colors.blue.shade200 : Colors.blue;
        textColor = isPast ? Colors.blue.shade900 : Colors.white;
        label = 'Р';
      } else {
        bgColor = isPast ? Colors.grey.shade100 : Colors.grey.shade300;
        textColor = isPast ? Colors.grey.shade400 : Colors.black87;
        label = null;
      }

      return GestureDetector(
        onTap: () => _showDayDetails(dayDate, isWork, dayEvents),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: isToday ? Border.all(color: Colors.blue, width: 2) : null,
            color: bgColor,
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: textColor,
                        fontWeight: isWork == true
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    if (label != null)
                      Text(
                        label,
                        style: TextStyle(color: textColor, fontSize: 8),
                      ),
                  ],
                ),
              ),
              if (dayEvents.isNotEmpty)
                Positioned(
                  left: 4,
                  right: 4,
                  bottom: 4,
                  child: Column(
                    children: dayEvents
                        .map(
                          (e) => Container(
                            height: 4,
                            margin: const EdgeInsets.only(top: 2),
                            decoration: BoxDecoration(
                              color: e.color,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      );
    });

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
      ),
      itemCount: emptyDays.length + days.length,
      itemBuilder: (context, index) {
        if (index < emptyDays.length) return emptyDays[index];
        return days[index - emptyDays.length];
      },
    );
  }

  Widget _buildStats() {
    int shiftsDone = 0;
    double totalHours = 0.0;

    if (_startDate != null) {
      final today = DateTime(
        DateTime.now().year,
        DateTime.now().month,
        DateTime.now().day,
      );
      final start = DateTime(
        _startDate!.year,
        _startDate!.month,
        _startDate!.day,
      );

      if (today.isAfter(start) || today.isAtSameMomentAs(start)) {
        final totalDays = today.difference(start).inDays + 1;
        for (int i = 0; i < totalDays; i++) {
          final date = start.add(Duration(days: i));
          final pos = i % 6;
          if (pos < 3) {
            shiftsDone++;
            totalHours += _getShiftDurationForDate(date);
          }
        }
      }
    }

    final totalEarned = totalHours * _hourlyRate;

    return GestureDetector(
      onTap: () {
        setState(() {
          _isStatsExpanded = !_isStatsExpanded;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Статистика', style: const TextStyle(fontSize: 16)),
                Icon(
                  _isStatsExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                ),
              ],
            ),
            if (_isStatsExpanded) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text(
                        'Смен',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      Text(
                        '$shiftsDone',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      const Text(
                        'Часов',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      Text(
                        '${totalHours.toStringAsFixed(1)}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      const Text(
                        'Заработано',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      Text(
                        '${totalEarned.toStringAsFixed(0)} ₽',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showSettingsDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Настройки'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Дата старта цикла'),
                      subtitle: Text(
                        _startDate == null
                            ? 'Не выбрана'
                            : '${_startDate!.day}.${_startDate!.month}.${_startDate!.year}',
                      ),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _startDate ?? DateTime.now(),
                          firstDate: DateTime(2026),
                          lastDate: DateTime(2030),
                          locale: const Locale('ru', 'RU'),
                        );
                        if (picked != null) {
                          setState(() {
                            _startDate = picked;
                          });
                          setStateDialog(() {});
                          _saveToCloud();
                        }
                      },
                    ),
                    const Divider(),
                    TextField(
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Стоимость часа (₽)',
                      ),
                      controller: TextEditingController(
                        text: _hourlyRate == 0 ? '' : _hourlyRate.toString(),
                      ),
                      onChanged: (v) {
                        final parsed = double.tryParse(v) ?? 0.0;
                        setState(() {
                          _hourlyRate = parsed;
                        });
                        _saveToCloud();
                      },
                    ),

                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Будни: Начало'),
                      trailing: TextButton(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: _weekdayStart,
                          );
                          if (picked != null) {
                            setState(() => _weekdayStart = picked);
                            setStateDialog(() {});
                            _saveToCloud();
                          }
                        },
                        child: Text(_weekdayStart.format(context)),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Будни: Конец'),
                      trailing: TextButton(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: _weekdayEnd,
                          );
                          if (picked != null) {
                            setState(() => _weekdayEnd = picked);
                            setStateDialog(() {});
                            _saveToCloud();
                          }
                        },
                        child: Text(_weekdayEnd.format(context)),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Выходные: Начало'),
                      trailing: TextButton(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: _weekendStart,
                          );
                          if (picked != null) {
                            setState(() => _weekendStart = picked);
                            setStateDialog(() {});
                            _saveToCloud();
                          }
                        },
                        child: Text(_weekendStart.format(context)),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Выходные: Конец'),
                      trailing: TextButton(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: _weekendEnd,
                          );
                          if (picked != null) {
                            setState(() => _weekendEnd = picked);
                            setStateDialog(() {});
                            _saveToCloud();
                          }
                        },
                        child: Text(_weekendEnd.format(context)),
                      ),
                    ),
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Уведомления'),
                      value: _notificationsEnabled,
                      onChanged: (v) {
                        setState(() => _notificationsEnabled = v);
                        setStateDialog(() {});
                        _saveToCloud();
                      },
                    ),
                    if (_notificationsEnabled) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'За часов',
                              ),
                              controller: TextEditingController(
                                text: _notifyHoursBefore.toString(),
                              ),
                              onChanged: (v) {
                                final parsed = int.tryParse(v) ?? 0;
                                setState(() => _notifyHoursBefore = parsed);
                                _saveToCloud();
                              },
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextField(
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'За минут',
                              ),
                              controller: TextEditingController(
                                text: _notifyMinutesBefore.toString(),
                              ),
                              onChanged: (v) {
                                final parsed = int.tryParse(v) ?? 0;
                                setState(() => _notifyMinutesBefore = parsed);
                                _saveToCloud();
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Версия приложения: $_appVersion',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Закрыть'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showDayDetails(DateTime date, bool? isWork, List<ShiftEvent> events) {
    String workStatus = 'Нет данных (до старта)';
    Color workColor = Colors.grey;

    if (isWork == true) {
      workStatus = 'Рабочая смена';
      workColor = Colors.blue;
    } else if (isWork == false) {
      workStatus = 'Выходной';
      workColor = Colors.grey.shade600;
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('${date.day} ${_months[date.month - 1]} ${date.year}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: workColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    workStatus,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const Divider(height: 24),
              const Text(
                'События:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (events.isEmpty)
                const Text('Нет событий', style: TextStyle(color: Colors.grey))
              else
                ...events.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: e.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.title),
                              if (e.startTime != null || e.endTime != null)
                                Text(
                                  '${e.startTime?.format(context) ?? '--:--'} - ${e.endTime?.format(context) ?? '--:--'}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit, size: 18),
                          onPressed: () {
                            Navigator.pop(context);
                            _addEventDialog(eventToEdit: e);
                          },
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete,
                            size: 18,
                            color: Colors.red,
                          ),
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Удалить событие?'),
                                content: Text(
                                  'Вы уверены, что хотите удалить "${e.title}"?',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Отмена'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text(
                                      'Удалить',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              setState(() {
                                _events.remove(e);
                              });
                              _saveToCloud();
                              Navigator.pop(context);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  void _addEventDialog({ShiftEvent? eventToEdit}) async {
    final result = await showDialog<ShiftEvent>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(
          text: eventToEdit?.title ?? '',
        );
        Color selectedColor = eventToEdit?.color ?? Colors.orange;
        DateTime selectedDate = eventToEdit?.date ?? DateTime.now();
        TimeOfDay? startTime = eventToEdit?.startTime;
        TimeOfDay? endTime = eventToEdit?.endTime;
        int? reminderMinutes = eventToEdit?.reminderMinutes;
        final List<Color> colors = [
          Colors.orange,
          Colors.purple,
          Colors.blue,
          Colors.red,
          Colors.teal,
        ];

        return AlertDialog(
          title: Text(
            eventToEdit == null ? 'Новое событие' : 'Редактировать событие',
          ),
          content: StatefulBuilder(
            builder: (context, setStateDialog) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'Название'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: colors.map((color) {
                      return GestureDetector(
                        onTap: () =>
                            setStateDialog(() => selectedColor = color),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: selectedColor == color
                                ? Border.all(color: Colors.black, width: 2)
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime(2026),
                        lastDate: DateTime(2030),
                        locale: const Locale('ru', 'RU'),
                      );
                      if (picked != null) {
                        setStateDialog(() => selectedDate = picked);
                      }
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                      '${selectedDate.day}.${selectedDate.month}.${selectedDate.year}',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: startTime ?? TimeOfDay.now(),
                          );
                          if (picked != null)
                            setStateDialog(() => startTime = picked);
                        },
                        icon: const Icon(Icons.access_time, size: 18),
                        label: Text(
                          startTime == null
                              ? 'Начало'
                              : startTime!.format(context),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: endTime ?? TimeOfDay.now(),
                          );
                          if (picked != null)
                            setStateDialog(() => endTime = picked);
                        },
                        icon: const Icon(Icons.access_time_filled, size: 18),
                        label: Text(
                          endTime == null ? 'Конец' : endTime!.format(context),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    value: reminderMinutes,
                    decoration: const InputDecoration(
                      labelText: 'Напомнить за...',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: null,
                        child: Text('Не напоминать'),
                      ),
                      DropdownMenuItem(value: 15, child: Text('15 минут')),
                      DropdownMenuItem(value: 30, child: Text('30 минут')),
                      DropdownMenuItem(value: 60, child: Text('1 час')),
                      DropdownMenuItem(value: 180, child: Text('3 часа')),
                      DropdownMenuItem(value: 1440, child: Text('1 день')),
                    ],
                    onChanged: (v) => setStateDialog(() => reminderMinutes = v),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  Navigator.pop(
                    context,
                    ShiftEvent(
                      date: selectedDate,
                      title: controller.text,
                      color: selectedColor,
                      startTime: startTime,
                      endTime: endTime,
                      reminderMinutes: reminderMinutes,
                    ),
                  );
                }
              },
              child: const Text('Добавить'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      setState(() {
        if (eventToEdit != null) {
          _events.remove(eventToEdit);
        }
        _events.add(result);
      });
      _saveToCloud();
    }
  }
}
