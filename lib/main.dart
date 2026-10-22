import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

enum PetEmotion { normal, happy, excited, thinking, sleepy, angry, wink }

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

  PetEmotion currentEmotion = PetEmotion.normal;
  String statusSubtitle = "Ketuk wajahku untuk berinteraksi!";
  String timeString = "";
  String dateString = "";

  late AnimationController _blinkController;
  late AnimationController _floatController;
  Timer? _clockTimer;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _updateClock();

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );

    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _idleTimer = Timer.periodic(const Duration(seconds: 4), (_) => _triggerBlink());
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
    });
  }

  Future<void> _saveSettings(
      String name, String persona, String url, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('petName', name);
    await prefs.setString('petPersona', persona);
    await prefs.setString('xiaozhiUrl', url);
    await prefs.setString('geminiApiKey', apiKey);
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

  void _triggerBlink() {
    if (mounted) {
      _blinkController.forward().then((_) => _blinkController.reverse());
    }
  }

  void _onFaceTapped() {
    final emotions = PetEmotion.values;
    final nextEmotion = emotions[Random().nextInt(emotions.length)];
    final responses = {
      PetEmotion.normal: "Halo! Aku $petName, siap menemanimu.",
      PetEmotion.happy: "Hehe, geli tau kalau disentuh!",
      PetEmotion.excited: "Wah! Ayo kita main sesuatu hari ini!",
      PetEmotion.thinking: "Hmm... kira-kira hari ini cuaca cerah nggak ya?",
      PetEmotion.sleepy: "Hoaaam... aku agak ngantuk nih...",
      PetEmotion.angry: "Jangan ди-tap keras-keras dong!",
      PetEmotion.wink: "Tenang, $petName selalu siap bantu kamu!",
    };

    setState(() {
      currentEmotion = nextEmotion;
      statusSubtitle = responses[nextEmotion]!;
    });
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _floatController.dispose();
    _clockTimer?.cancel();
    _idleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // HUD Bar Atas (Nama Pet, Waktu, Pengaturan)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        petName.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          color: Colors.cyanAccent,
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

            // Area Wajah Ekspresif Pet
            Expanded(
              child: GestureDetector(
                onTap: _onFaceTapped,
                child: Center(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_blinkController, _floatController]),
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(0, (_floatController.value - 0.5) * 16),
                        child: CustomPaint(
                          size: const Size(300, 220),
                          painter: RobotFacePainter(
                            emotion: currentEmotion,
                            blinkValue: _blinkController.value,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),

            // Teks Subtitle Suara / Pikiran Pet
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                ),
                child: Text(
                  statusSubtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),

            // Panel Tombol Eksperimen Ekspresi (Tahap 1)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 20, left: 16, right: 16),
              child: Row(
                children: PetEmotion.values.map((e) {
                  final isSelected = currentEmotion == e;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(e.name.toUpperCase()),
                      selected: isSelected,
                      selectedColor: Colors.cyanAccent.withOpacity(0.3),
                      onSelected: (_) => setState(() => currentEmotion = e),
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

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Pengaturan Persona & AI"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: "Nama Pet"),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: personaCtrl,
                maxLines: 2,
                decoration: const InputDecoration(labelText: "Sifat / Persona"),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(labelText: "XiaoZhi Server WS"),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: keyCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "Gemini API Key (Opsional untuk Kamera)",
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
              );
              Navigator.pop(context);
            },
            child: const Text("Simpan"),
          ),
        ],
      ),
    );
  }
}

class RobotFacePainter extends CustomPainter {
  final PetEmotion emotion;
  final double blinkValue;

  RobotFacePainter({required this.emotion, required this.blinkValue});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);

    double eyeWidth = 65;
    double eyeHeight = 80 * (1.0 - blinkValue * 0.9);
    double leftEyeX = size.width * 0.25;
    double rightEyeX = size.width * 0.75;
    double eyeY = size.height * 0.42;

    if (emotion == PetEmotion.sleepy) {
      eyeHeight *= 0.25;
    } else if (emotion == PetEmotion.excited) {
      eyeHeight *= 1.15;
    }

    // Gambar Mata Kiri & Kanan
    _drawEye(canvas, Offset(leftEyeX, eyeY), eyeWidth, eyeHeight, paint, glowPaint, true);
    _drawEye(
      canvas,
      Offset(rightEyeX, eyeY),
      eyeWidth,
      emotion == PetEmotion.wink ? eyeHeight * 0.15 : eyeHeight,
      paint,
      glowPaint,
      false,
    );

    // Gambar Mulut
    final mouthPaint = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    final mouthCenter = Offset(size.width * 0.5, size.height * 0.78);
    if (emotion == PetEmotion.happy || emotion == PetEmotion.excited || emotion == PetEmotion.wink) {
      canvas.drawArc(
        Rect.fromCenter(center: mouthCenter, width: 60, height: 40),
        0,
        pi,
        false,
        mouthPaint,
      );
    } else if (emotion == PetEmotion.angry) {
      canvas.drawArc(
        Rect.fromCenter(center: mouthCenter.translate(0, 15), width: 50, height: 30),
        pi,
        pi,
        false,
        mouthPaint,
      );
    } else if (emotion == PetEmotion.thinking) {
      canvas.drawLine(
        mouthCenter.translate(-20, 5),
        mouthCenter.translate(20, -5),
        mouthPaint,
      );
    } else {
      canvas.drawArc(
        Rect.fromCenter(center: mouthCenter, width: 40, height: 20),
        0,
        pi,
        false,
        mouthPaint,
      );
    }
  }

  void _drawEye(Canvas canvas, Offset center, double w, double h, Paint paint,
      Paint glowPaint, bool isLeft) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: w, height: h),
      const Radius.circular(24),
    );
    canvas.drawRRect(rect, glowPaint);
    canvas.drawRRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant RobotFacePainter oldDelegate) =>
      oldDelegate.emotion != emotion || oldDelegate.blinkValue != blinkValue;
}
