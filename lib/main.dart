import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';

import 'package:package_info_plus/package_info_plus.dart';

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

  ShiftEvent({
    required this.date,
    required this.title,
    required this.color,
    this.startTime,
    this.endTime,
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
  bool _isStatsExpanded = false;
  bool _isLoading = true;
  String _appVersion = '';

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
    _loadFromCloud();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _appVersion = '${info.version}+${info.buildNumber}';
    });
  }

  Future<void> _loadFromCloud() async {
    if (_user == null) {
      setState(() => _isLoading = false);
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

  Future<void> _saveToCloud() async {
    if (_user == null) return;
    try {
      await _db.collection('users').doc(_user!.uid).set({
        'start_date': _startDate?.toIso8601String(),
        'hourly_rate': _hourlyRate,
        'shift_hours': _shiftHours,
        'events': _events.map((e) => e.toMap()).toList(),
      });
    } catch (e) {
      debugPrint('Ошибка сохранения в облако: $e');
    }
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
      body: Column(
        children: [
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
                backgroundColor: Colors.blue.shade50,
                foregroundColor: Colors.blue.shade900,
                elevation: 0,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Добавить событие',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
          _buildStats(),
        ],
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
        label = 'раб';
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
        final fullCycles = totalDays ~/ 6;
        final remainder = totalDays % 6;
        shiftsDone = fullCycles * 3 + (remainder > 3 ? 3 : remainder);
      }
    }

    final totalHours = shiftsDone * _shiftHours;
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
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Статистика',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
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
                    const SizedBox(height: 8),
                    TextField(
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Часов в смене',
                      ),
                      controller: TextEditingController(
                        text: _shiftHours.toString(),
                      ),
                      onChanged: (v) {
                        final parsed = double.tryParse(v) ?? 12.0;
                        setState(() {
                          _shiftHours = parsed;
                        });
                        _saveToCloud();
                      },
                    ),
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
