import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const XiaoZhiPetApp());
}

class XiaoZhiPetApp extends StatelessWidget {
  const XiaoZhiPetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XiaoZhi AI Pet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(primary: Colors.cyanAccent),
      ),
      home: const PetHomeScreen(),
    );
  }
}

enum PetEmotion {
  normal,
  happy,
  love,
  excited,
  thinking,
  surprised,
  sad,
  crying,
  angry,
  sleepy,
  wink,
  dizzy
}

class FloatingParticle {
  Offset position;
  double opacity;
  double size;
  String symbol;
  Color color;

  FloatingParticle({
    required this.position,
    this.opacity = 1.0,
    this.size = 24.0,
    required this.symbol,
    required this.color,
  });
}

class PetHomeScreen extends StatefulWidget {
  const PetHomeScreen({super.key});

  @override
  State<PetHomeScreen> createState() => _PetHomeScreenState();
}

class _PetHomeScreenState extends State<PetHomeScreen>
    with TickerProviderStateMixin {
  String petName = "Mochi";
  String petPersona = "Ceria, ekspresif, suka mengajak ngobrol duluan";
  String xiaozhiUrl = "wss://api.tenclass.net/xiaozhi/v1/";
  String geminiApiKey = "";
  int themeColorIndex = 0;

  final List<Color> themeColors = [
    Colors.cyanAccent,
    Colors.pinkAccent,
    Colors.greenAccent,
    Colors.amberAccent,
    Colors.purpleAccent,
  ];

  PetEmotion currentEmotion = PetEmotion.normal;
  String statusSubtitle = "Elus kepalaku, geser layar, atau goyangkan HP!";
  String timeString = "";
  String dateString = "";
  bool isLandscape = false;
  bool isTalking = false;

  // Posisi lirikan mata (-1.0 sampai 1.0)
  Offset gazeOffset = Offset.zero;
  int rubCounter = 0;
  final List<FloatingParticle> particles = [];

  late AnimationController _blinkController;
  late AnimationController _floatController;
  late AnimationController _talkController;
  Timer? _clockTimer;
  Timer? _idleTimer;
  Timer? _particleTimer;
  Timer? _talkStopTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime _lastShakeTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _updateClock();

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );

    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _talkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..repeat(reverse: true);

    _clockTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _idleTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _idleBehavior());
    _particleTimer = Timer.periodic(
        const Duration(milliseconds: 50), (_) => _updateParticles());

    _initShakeDetector();
  }

  void _initShakeDetector() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      double gForce =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (gForce > 22.0) {
        final now = DateTime.now();
        if (now.difference(_lastShakeTime).inSeconds > 3) {
          _lastShakeTime = now;
          _speakWithEmotion(
            PetEmotion.dizzy,
            "Aduh pusinggg! Jangan dikocok-kocok dong HP-nya!",
          );
          _spawnParticle("💫", Colors.yellowAccent);
        }
      }
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      petName = prefs.getString('petName') ?? "Mochi";
      petPersona = prefs.getString('petPersona') ??
          "Ceria, ekspresif, suka mengajak ngobrol duluan";
      xiaozhiUrl =
          prefs.getString('xiaozhiUrl') ?? "wss://api.tenclass.net/xiaozhi/v1/";
      geminiApiKey = prefs.getString('geminiApiKey') ?? "";
      themeColorIndex = prefs.getInt('themeColorIndex') ?? 0;
    });
  }

  Future<void> _saveSettings(
      String name, String persona, String url, String apiKey, int colorIdx) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('petName', name);
    await prefs.setString('petPersona', persona);
    await prefs.setString('xiaozhiUrl', url);
    await prefs.setString('geminiApiKey', apiKey);
    await prefs.setInt('themeColorIndex', colorIdx);
    _loadSettings();
  }

  void _updateClock() {
    final now = DateTime.now();
    final days = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
      'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'
    ];
    setState(() {
      timeString =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
      dateString =
          "${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}";
    });
  }

  void _idleBehavior() {
    if (!mounted) return;
    _blinkController.forward().then((_) => _blinkController.reverse());

    // Gerakan lirik mata acak secara halus saat idle
    final rand = Random();
    if (rand.nextBool()) {
      setState(() {
        gazeOffset = Offset(
          (rand.nextDouble() - 0.5) * 0.5,
          (rand.nextDouble() - 0.5) * 0.3,
        );
      });
    } else {
      setState(() => gazeOffset = Offset.zero);
    }

    if (currentEmotion == PetEmotion.sleepy) {
      _spawnParticle("Zzz", Colors.cyanAccent);
    } else if (currentEmotion == PetEmotion.crying) {
      _spawnParticle("💧", Colors.lightBlueAccent);
    }
  }

  void _spawnParticle(String symbol, Color color, {Offset? customPos}) {
    final rand = Random();
    setState(() {
      particles.add(
        FloatingParticle(
          position: customPos ??
              Offset(
                120 + rand.nextDouble() * 120,
                40 + rand.nextDouble() * 60,
              ),
          symbol: symbol,
          color: color,
        ),
      );
    });
  }

  void _updateParticles() {
    if (particles.isEmpty) return;
    setState(() {
      for (var p in particles) {
        p.position = p.position.translate(0, -2.2);
        p.opacity -= 0.03;
      }
      particles.removeWhere((p) => p.opacity <= 0);
    });
  }

  void _speakWithEmotion(PetEmotion emotion, String text) {
    _talkStopTimer?.cancel();
    setState(() {
      currentEmotion = emotion;
      statusSubtitle = text;
      isTalking = true;
    });
    int durationMs = (text.length * 65).clamp(1200, 4000);
    _talkStopTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) setState(() => isTalking = false);
    });
  }

  void _toggleOrientation() {
    setState(() => isLandscape = !isLandscape);
    if (isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  void _onFaceTapDown(TapDownDetails details, Size faceAreaSize) {
    final local = details.localPosition;
    final centerX = faceAreaSize.width / 2;
    final centerY = faceAreaSize.height / 2;

    // Cek apakah menyentuh tepat di area mata kiri atau kanan
    final leftEyeCenter = Offset(centerX - 75, centerY - 20);
    final rightEyeCenter = Offset(centerX + 75, centerY - 20);

    if ((local - leftEyeCenter).distance < 45 ||
        (local - rightEyeCenter).distance < 45) {
      _speakWithEmotion(
        PetEmotion.angry,
        "Aduh! Jangan colok mataku dong, perih tau!",
      );
      _spawnParticle("💢", Colors.redAccent);
      return;
    }

    // Respon ketukan biasa secara interaktif
    final pairs = [
      (PetEmotion.happy, "Hehe, halo! Senang banget kamu ajak main!"),
      (PetEmotion.excited, "Wah! Kita mau ngapain nih sekarang?"),
      (PetEmotion.wink, "Tenang aja, $petName selalu siap nemenin kamu!"),
      (PetEmotion.surprised, "Eh! Kamu ngagetin aku aja nih!"),
      (PetEmotion.thinking, "Hmm... coba elus bagian atas kepalaku deh!"),
    ];
    final pick = pairs[Random().nextInt(pairs.length)];
    _speakWithEmotion(pick.$1, pick.$2);
  }

  void _onFacePanUpdate(DragUpdateDetails details, Size faceAreaSize) {
    final local = details.localPosition;
    final dx = ((local.dx / faceAreaSize.width) - 0.5) * 2.0;
    final dy = ((local.dy / faceAreaSize.height) - 0.5) * 2.0;

    setState(() {
      gazeOffset = Offset(dx.clamp(-1.0, 1.0), dy.clamp(-1.0, 1.0));
    });

    // Jika mengelus bagian dahi / atas kepala
    if (dy < -0.15) {
      rubCounter++;
      if (rubCounter % 12 == 0) {
        _spawnParticle("❤️", Colors.pinkAccent);
        if (currentEmotion != PetEmotion.love) {
          _speakWithEmotion(
            PetEmotion.love,
            "Senangnya dielus-elus... jadi makin sayang deh!",
          );
        }
      }
    }
  }

  void _onFacePanEnd(DragEndDetails details) {
    rubCounter = 0;
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => gazeOffset = Offset.zero);
    });
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _floatController.dispose();
    _talkController.dispose();
    _clockTimer?.cancel();
    _idleTimer?.cancel();
    _particleTimer?.cancel();
    _talkStopTimer?.cancel();
    _accelSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = currentEmotion == PetEmotion.angry
        ? Colors.redAccent
        : currentEmotion == PetEmotion.love
            ? Colors.pinkAccent
            : themeColors[themeColorIndex];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // HUD Bar Atas
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          isLandscape
                              ? Icons.stay_current_portrait
                              : Icons.stay_current_landscape,
                          color: Colors.white70,
                          size: 20,
                        ),
                        tooltip: "Putar Layar (Mode Meja)",
                        onPressed: _toggleOrientation,
                      ),
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: baseColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: baseColor, blurRadius: 6)
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        petName.toUpperCase(),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          color: baseColor,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Text(
                        timeString,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        dateString,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings, color: Colors.white70),
                    onPressed: _showSettingsDialog,
                  ),
                ],
              ),
            ),

            // Kanvas Wajah Robot Ekspresif + Partikel
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _onFaceTapDown(d, size),
                    onPanUpdate: (d) => _onFacePanUpdate(d, size),
                    onPanEnd: _onFacePanEnd,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedBuilder(
                          animation: Listenable.merge([
                            _blinkController,
                            _floatController,
                            _talkController,
                          ]),
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(
                                gazeOffset.dx * 12,
                                (_floatController.value - 0.5) * 14 +
                                    gazeOffset.dy * 8,
                              ),
                              child: CustomPaint(
                                size: const Size(320, 220),
                                painter: RobotFacePainter(
                                  emotion: currentEmotion,
                                  blinkValue: _blinkController.value,
                                  talkValue:
                                      isTalking ? _talkController.value : 0.0,
                                  gazeOffset: gazeOffset,
                                  faceColor: baseColor,
                                ),
                              ),
                            );
                          },
                        ),
                        // Lapisan Partikel Melayang (Hati, Zzz, Air Mata)
                        ...particles.map(
                          (p) => Positioned(
                            left: (size.width / 2 - 160) + p.position.dx,
                            top: (size.height / 2 - 110) + p.position.dy,
                            child: Opacity(
                              opacity: p.opacity.clamp(0.0, 1.0),
                              child: Text(
                                p.symbol,
                                style: TextStyle(
                                  fontSize: p.size,
                                  color: p.color,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            // Kotak Subtitle Bicara
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: baseColor.withOpacity(0.35)),
                ),
                child: Text(
                  statusSubtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, color: Colors.white),
                ),
              ),
            ),

            // Bar Pilihan Ekspresi Lengkap
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 14, left: 16, right: 16),
              child: Row(
                children: PetEmotion.values.map((e) {
                  final isSelected = currentEmotion == e;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(
                        e.name.toUpperCase(),
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: isSelected,
                      selectedColor: baseColor.withOpacity(0.3),
                      onSelected: (_) {
                        _speakWithEmotion(
                          e,
                          "Ekspresi diubah ke mode ${e.name}!",
                        );
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettingsDialog() {
    final nameCtrl = TextEditingController(text: petName);
    final personaCtrl = TextEditingController(text: petPersona);
    final urlCtrl = TextEditingController(text: xiaozhiUrl);
    final keyCtrl = TextEditingController(text: geminiApiKey);
    int selectedColor = themeColorIndex;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Pengaturan Persona & Wajah"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Warna Mata Neon:", style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: List.generate(themeColors.length, (idx) {
                    return GestureDetector(
                      onTap: () => setDialogState(() => selectedColor = idx),
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: themeColors[idx],
                        child: selectedColor == idx
                            ? const Icon(Icons.check,
                                color: Colors.black, size: 18)
                            : null,
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: "Nama Pet"),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: personaCtrl,
                  maxLines: 2,
                  decoration:
                      const InputDecoration(labelText: "Sifat / Persona"),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: urlCtrl,
                  decoration:
                      const InputDecoration(labelText: "XiaoZhi Server WS"),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: keyCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: "Gemini API Key (Untuk Kamera/Suara)",
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Batal"),
            ),
            ElevatedButton(
              onPressed: () {
                _saveSettings(
                  nameCtrl.text,
                  personaCtrl.text,
                  urlCtrl.text,
                  keyCtrl.text,
                  selectedColor,
                );
                Navigator.pop(context);
              },
              child: const Text("Simpan"),
            ),
          ],
        ),
      ),
    );
  }
}

class RobotFacePainter extends CustomPainter {
  final PetEmotion emotion;
  final double blinkValue;
  final double talkValue;
  final Offset gazeOffset;
  final Color faceColor;

  RobotFacePainter({
    required this.emotion,
    required this.blinkValue,
    required this.talkValue,
    required this.gazeOffset,
    required this.faceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = faceColor.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);

    double eyeWidth = 68;
    double eyeHeight = 82 * (1.0 - blinkValue * 0.92);

    final gazeShift = Offset(gazeOffset.dx * 18, gazeOffset.dy * 14);
    final leftCenter = Offset(size.width * 0.26, size.height * 0.42) + gazeShift;
    final rightCenter =
        Offset(size.width * 0.74, size.height * 0.42) + gazeShift;

    // Gambar Kedua Mata Berdasarkan Emosi
    _drawCustomEye(
        canvas, leftCenter, eyeWidth, eyeHeight, paint, glowPaint, true);
    _drawCustomEye(
        canvas, rightCenter, eyeWidth, eyeHeight, paint, glowPaint, false);

    // Pipi Merona saat Happy / Love
    if (emotion == PetEmotion.love || emotion == PetEmotion.happy) {
      final blushPaint = Paint()
        ..color = Colors.pinkAccent.withOpacity(0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawOval(
        Rect.fromCenter(
            center: leftCenter.translate(-20, 52), width: 34, height: 16),
        blushPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
            center: rightCenter.translate(20, 52), width: 34, height: 16),
        blushPaint,
      );
    }

    // Gambar Mulut & Animasi Bicara
    _drawMouth(canvas, size, gazeShift * 0.5);
  }

  void _drawCustomEye(Canvas canvas, Offset center, double w, double h,
      Paint paint, Paint glowPaint, bool isLeft) {
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;

    if (emotion == PetEmotion.wink && !isLeft) {
      canvas.drawArc(
        Rect.fromCenter(center: center, width: w, height: 25),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == PetEmotion.happy) {
      // Mata melengkung bahagia ^ ^
      canvas.drawArc(
        Rect.fromCenter(center: center.translate(0, 10), width: w, height: 55),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == PetEmotion.dizzy) {
      // Mata bentuk X X saat HP digoyang
      double r = 24;
      canvas.drawLine(center.translate(-r, -r), center.translate(r, r), strokePaint);
      canvas.drawLine(center.translate(r, -r), center.translate(-r, r), strokePaint);
      return;
    }

    if (emotion == PetEmotion.love) {
      // Mata bentuk Hati
      final path = Path();
      double s = 34;
      path.moveTo(center.dx, center.dy + s * 0.8);
      path.cubicTo(center.dx - s * 1.4, center.dy, center.dx - s * 0.7,
          center.dy - s * 1.1, center.dx, center.dy - s * 0.3);
      path.cubicTo(center.dx + s * 0.7, center.dy - s * 1.1,
          center.dx + s * 1.4, center.dy, center.dx, center.dy + s * 0.8);
      canvas.drawPath(path, glowPaint);
      canvas.drawPath(path, paint);
      return;
    }

    if (emotion == PetEmotion.sleepy) {
      h *= 0.22;
    } else if (emotion == PetEmotion.surprised) {
      w = 72;
      h = 72 * (1.0 - blinkValue * 0.9);
    } else if (emotion == PetEmotion.excited) {
      h *= 1.15;
    }

    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: w, height: h),
      Radius.circular(emotion == PetEmotion.surprised ? 40 : 24),
    );
    canvas.drawRRect(rect, glowPaint);
    canvas.drawRRect(rect, paint);

    // Kelopak miring untuk ekspresi Angry / Sad / Crying
    final maskPaint = Paint()..color = Colors.black;
    if (emotion == PetEmotion.angry) {
      final path = Path();
      if (isLeft) {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - 5);
        path.lineTo(center.dx - w, center.dy - h * 0.55);
      } else {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h * 0.55);
        path.lineTo(center.dx - w, center.dy - 5);
      }
      path.close();
      canvas.drawPath(path, maskPaint);
    } else if (emotion == PetEmotion.sad || emotion == PetEmotion.crying) {
      final path = Path();
      if (isLeft) {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h * 0.55);
        path.lineTo(center.dx - w, center.dy - 5);
      } else {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - 5);
        path.lineTo(center.dx - w, center.dy - h * 0.55);
      }
      path.close();
      canvas.drawPath(path, maskPaint);
    }
  }

  void _drawMouth(Canvas canvas, Size size, Offset shift) {
    final mouthCenter =
        Offset(size.width * 0.5, size.height * 0.78) + shift;
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

    // Jika sedang berbicara (Lip-Sync aktif)
    if (talkValue > 0.05) {
      double openH = 14 + (talkValue * 28);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: mouthCenter, width: 48, height: openH),
          const Radius.circular(18),
        ),
        fillPaint,
      );
      return;
    }

    switch (emotion) {
      case PetEmotion.happy:
      case PetEmotion.love:
      case PetEmotion.excited:
      case PetEmotion.wink:
        canvas.drawArc(
          Rect.fromCenter(center: mouthCenter, width: 62, height: 42),
          0,
          pi,
          false,
          strokePaint,
        );
        break;
      case PetEmotion.angry:
      case PetEmotion.sad:
      case PetEmotion.crying:
        canvas.drawArc(
          Rect.fromCenter(
              center: mouthCenter.translate(0, 16), width: 52, height: 32),
          pi,
          pi,
          false,
          strokePaint,
        );
        break;
      case PetEmotion.surprised:
      case PetEmotion.dizzy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 28, height: 32),
          strokePaint,
        );
        break;
      case PetEmotion.thinking:
        canvas.drawLine(
          mouthCenter.translate(-22, 5),
          mouthCenter.translate(20, -6),
          strokePaint,
        );
        break;
      case PetEmotion.sleepy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 18, height: 18),
          strokePaint,
        );
        break;
      default:
        canvas.drawArc(
          Rect.fromCenter(center: mouthCenter, width: 44, height: 22),
          0,
          pi,
          false,
          strokePaint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant RobotFacePainter oldDelegate) => true;
}
