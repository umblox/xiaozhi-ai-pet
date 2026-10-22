import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

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
  // Identitas & Konfigurasi Pet
  String petName = "Mochi";
  String petPersona =
      "Robot peliharaan AI yang ceria, ekspresif, perhatian, dan suka memulai obrolan duluan";
  String selectedLang = "id-ID";
  String xiaozhiUrl = "wss://api.tenclass.net/xiaozhi/v1/";
  String geminiApiKey = "";
  int themeColorIndex = 0;
  bool autoProactive = true;

  // Identitas Virtual ESP32 untuk XiaoZhi
  String deviceMac = "";
  String clientId = "";
  String pairingCode = "";
  bool isXiaoZhiConnected = false;
  WebSocket? _xiaozhiWs;

  // Data Konteks Cuaca & Waktu Real-Time
  String cityName = "Lokasimu";
  String weatherSummary = "Memuat cuaca...";
  String timeString = "";
  String dateString = "";

  // Mesin Suara (TTS & STT)
  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool isListening = false;
  bool isThinking = false;
  bool isTalking = false;
  bool isLandscape = false;

  final List<Color> themeColors = [
    Colors.cyanAccent,
    Colors.pinkAccent,
    Colors.greenAccent,
    Colors.amberAccent,
    Colors.purpleAccent,
  ];

  final Map<String, String> languageOptions = {
    "id-ID": "Bahasa Indonesia",
    "en-US": "English (Inggris)",
    "ja-JP": "日本語 (Jepang)",
    "zh-CN": "中文 (Mandarin)",
    "jv-ID": "Bahasa Indonesia (Gaya Jawa Akrab)",
    "su-ID": "Bahasa Indonesia (Gaya Sunda Akrab)",
  };

  PetEmotion currentEmotion = PetEmotion.normal;
  String statusSubtitle = "Halo! Ketuk mikrofon untuk ngobrol denganku!";
  final List<Map<String, String>> chatHistory = [];

  Offset gazeOffset = Offset.zero;
  int rubCounter = 0;
  final List<FloatingParticle> particles = [];

  late AnimationController _blinkController;
  late AnimationController _floatController;
  late AnimationController _talkController;
  Timer? _clockTimer;
  Timer? _idleTimer;
  Timer? _particleTimer;
  Timer? _proactiveTimer;
  Timer? _talkStopTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime _lastShakeTime = DateTime.now();
  DateTime _lastInteractionTime = DateTime.now();

  @override
  void initState() {
    super.initState();
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
      duration: const Duration(milliseconds: 170),
    )..repeat(reverse: true);

    _updateClock();
    _initEverything();

    _clockTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _idleTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _idleBehavior());
    _particleTimer = Timer.periodic(
        const Duration(milliseconds: 50), (_) => _updateParticles());

    // Timer Inisiatif Ngobrol Duluan setiap 90 detik jika user diam
    _proactiveTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkProactive());

    _initShakeDetector();
  }

  Future<void> _initEverything() async {
    await _loadSettings();
    await _initTts();
    await _fetchLocationAndWeather();
    _connectXiaoZhiWebSocket();

    // Sapaan otomatis saat aplikasi baru dibuka
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && chatHistory.isEmpty) {
        _triggerProactiveGreeting(isInitial: true);
      }
    });
  }

  Future<void> _initTts() async {
    String ttsLang = selectedLang;
    if (ttsLang == "jv-ID" || ttsLang == "su-ID") ttsLang = "id-ID";
    await _tts.setLanguage(ttsLang);
    await _tts.setPitch(1.15);
    await _tts.setSpeechRate(0.52);

    _tts.setStartHandler(() {
      if (mounted) setState(() => isTalking = true);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => isTalking = false);
    });
    _tts.setErrorHandler((_) {
      if (mounted) setState(() => isTalking = false);
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedMac = prefs.getString('deviceMac');
    String? savedClient = prefs.getString('clientId');

    if (savedMac == null || savedMac.isEmpty) {
      final rand = Random();
      savedMac =
          "02:00:5e:${rand.nextInt(256).toRadixString(16).padLeft(2, '0')}:${rand.nextInt(256).toRadixString(16).padLeft(2, '0')}:${rand.nextInt(256).toRadixString(16).padLeft(2, '0')}";
      await prefs.setString('deviceMac', savedMac);
    }
    if (savedClient == null || savedClient.isEmpty) {
      final rand = Random();
      savedClient =
          "c4f2a1b0-${rand.nextInt(9000) + 1000}-4e1a-9b2c-${rand.nextInt(900000) + 100000}a1b2c3";
      await prefs.setString('clientId', savedClient);
    }

    setState(() {
      deviceMac = savedMac!;
      clientId = savedClient!;
      petName = prefs.getString('petName') ?? "Mochi";
      petPersona = prefs.getString('petPersona') ??
          "Robot peliharaan AI yang ceria, ekspresif, perhatian, dan suka memulai obrolan duluan";
      selectedLang = prefs.getString('selectedLang') ?? "id-ID";
      xiaozhiUrl =
          prefs.getString('xiaozhiUrl') ?? "wss://api.tenclass.net/xiaozhi/v1/";
      geminiApiKey = prefs.getString('geminiApiKey') ?? "";
      themeColorIndex = prefs.getInt('themeColorIndex') ?? 0;
      autoProactive = prefs.getBool('autoProactive') ?? true;
    });
  }

  Future<void> _saveSettings({
    required String name,
    required String persona,
    required String lang,
    required String url,
    required String apiKey,
    required int colorIdx,
    required bool proactive,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('petName', name);
    await prefs.setString('petPersona', persona);
    await prefs.setString('selectedLang', lang);
    await prefs.setString('xiaozhiUrl', url);
    await prefs.setString('geminiApiKey', apiKey);
    await prefs.setInt('themeColorIndex', colorIdx);
    await prefs.setBool('autoProactive', proactive);
    await _loadSettings();
    await _initTts();
  }

  // Ambil Lokasi & Cuaca Real-Time Tanpa Perlu GPS Rumit
  Future<void> _fetchLocationAndWeather() async {
    try {
      double lat = -6.2088;
      double lon = 106.8456;
      String detectedCity = "Indonesia";

      final geoRes = await http
          .get(Uri.parse("http://ip-api.com/json"))
          .timeout(const Duration(seconds: 5));
      if (geoRes.statusCode == 200) {
        final geoData = jsonDecode(geoRes.body);
        lat = (geoData['lat'] as num?)?.toDouble() ?? lat;
        lon = (geoData['lon'] as num?)?.toDouble() ?? lon;
        detectedCity = geoData['city'] ?? "Indonesia";
      }

      final weatherUrl =
          "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current_weather=true";
      final wRes = await http
          .get(Uri.parse(weatherUrl))
          .timeout(const Duration(seconds: 6));

      if (wRes.statusCode == 200) {
        final wData = jsonDecode(wRes.body);
        final current = wData['current_weather'];
        final temp = current['temperature'];
        final code = current['weathercode'] as int;
        final desc = _mapWeatherCode(code);

        if (mounted) {
          setState(() {
            cityName = detectedCity;
            weatherSummary = "$temp°C $desc • $detectedCity";
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => weatherSummary = "Cuaca Cerah • Online");
      }
    }
  }

  String _mapWeatherCode(int code) {
    if (code == 0) return "Cerah";
    if (code <= 3) return "Berawan";
    if (code <= 48) return "Berkabut";
    if (code <= 67) return "Hujan";
    if (code <= 82) return "Hujan Deras";
    if (code >= 95) return "Badai Petir";
    return "Cerah Berawan";
  }

  // Protokol Resmi OTA XiaoZhi untuk Kode Pairing 6 Digit
  Future<void> _checkXiaoZhiOtaPairing() async {
    setState(() {
      statusSubtitle = "Menghubungi server OTA XiaoZhi...";
      currentEmotion = PetEmotion.thinking;
    });

    try {
      final response = await http
          .post(
            Uri.parse("https://api.tenclass.net/xiaozhi/ota/"),
            headers: {
              "Device-Id": deviceMac,
              "Client-Id": clientId,
              "Content-Type": "application/json",
              "User-Agent": "bread-compact-wifi/1.0.0",
              "Accept-Language": selectedLang,
            },
            body: jsonEncode({
              "version": 2,
              "language": selectedLang,
              "flash_size": 16777216,
              "minimum_free_heap_size": 8388608,
              "mac_address": deviceMac,
              "uuid": clientId,
              "chip_model_name": "esp32s3",
              "application": {
                "name": "xiaozhi",
                "version": "1.6.0",
                "compile_time": "Oct 23 2026",
                "idf_version": "v5.3.2"
              },
              "board": {
                "type": "bread-compact-wifi",
                "name": "bread-compact-wifi",
                "ssid": "Android-AI-Pet",
                "rssi": -42,
                "channel": 1,
                "ip": "192.168.1.100",
                "mac": deviceMac
              }
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data['activation'] != null && data['activation']['code'] != null) {
          final code = data['activation']['code'].toString();
          setState(() {
            pairingCode = code;
          });
          _speakWithEmotion(
            PetEmotion.excited,
            "Kode pairing XiaoZhi kamu adalah: ${code.split('').join(' ')}. Masukkan di web xiaozhi.me ya!",
          );
          _showPairingDialog(code, data['activation']['message']?.toString());
        } else {
          setState(() => pairingCode = "SUDAH AKTIF");
          _speakWithEmotion(
            PetEmotion.happy,
            "Perangkat ini sudah terhubung dengan server XiaoZhi!",
          );
          _connectXiaoZhiWebSocket();
        }
      } else {
        _speakWithEmotion(
          PetEmotion.sad,
          "Server XiaoZhi merespon dengan kode ${response.statusCode}.",
        );
      }
    } catch (e) {
      _speakWithEmotion(
        PetEmotion.sad,
        "Gagal mengambil kode OTA XiaoZhi, tapi aku tetap bisa ngobrol langsung denganmu!",
      );
    }
  }

  // Koneksi WebSocket XiaoZhi
  Future<void> _connectXiaoZhiWebSocket() async {
    try {
      _xiaozhiWs?.close();
      final ws = await WebSocket.connect(
        xiaozhiUrl,
        headers: {
          "Authorization": "Bearer test-token",
          "Protocol-Version": "1",
          "Device-Id": deviceMac,
          "Client-Id": clientId,
        },
      ).timeout(const Duration(seconds: 8));

      _xiaozhiWs = ws;
      if (mounted) setState(() => isXiaoZhiConnected = true);

      // Kirim paket Hello standar protokol XiaoZhi
      ws.add(jsonEncode({
        "type": "hello",
        "version": 1,
        "transport": "websocket",
        "audio_params": {
          "format": "opus",
          "sample_rate": 16000,
          "channels": 1,
          "frame_duration": 60
        }
      }));

      ws.listen(
        (message) {
          if (message is String) {
            _handleXiaoZhiJsonMessage(message);
          }
        },
        onDone: () {
          if (mounted) setState(() => isXiaoZhiConnected = false);
        },
        onError: (_) {
          if (mounted) setState(() => isXiaoZhiConnected = false);
        },
      );
    } catch (_) {
      if (mounted) setState(() => isXiaoZhiConnected = false);
    }
  }

  void _handleXiaoZhiJsonMessage(String rawJson) {
    try {
      final data = jsonDecode(rawJson);
      final type = data['type'];

      if (type == 'llm' && data['emotion'] != null) {
        final emo = _parseEmotionString(data['emotion'].toString());
        setState(() => currentEmotion = emo);
      } else if (type == 'tts') {
        final state = data['state'];
        final text = data['text']?.toString() ?? "";
        if ((state == 'sentence_start' || state == 'start') &&
            text.isNotEmpty) {
          _speakWithEmotion(currentEmotion, text);
        }
      }
    } catch (_) {}
  }

  // Fungsi Mendengarkan Suara Mikrofon (Speech-to-Text)
  Future<void> _toggleListening() async {
    _lastInteractionTime = DateTime.now();
    if (isListening) {
      await _speech.stop();
      setState(() => isListening = false);
      return;
    }

    await _tts.stop();
    bool available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => isListening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => isListening = false);
      },
    );

    if (available) {
      setState(() {
        isListening = true;
        currentEmotion = PetEmotion.normal;
        statusSubtitle = "Aku sedang mendengarkanmu... silakan bicara!";
      });

      String sttLocale = selectedLang;
      if (sttLocale == "jv-ID" || sttLocale == "su-ID") sttLocale = "id-ID";

      _speech.listen(
        localeId: sttLocale,
        onResult: (result) {
          setState(() {
            statusSubtitle = "\"${result.recognizedWords}\"";
          });
          if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
            setState(() => isListening = false);
            _askAiBrain(result.recognizedWords.trim());
          }
        },
      );
    } else {
      _speakWithEmotion(
        PetEmotion.sad,
        "Izin mikrofon belum aktif. Kamu juga bisa mengetik pesan di tombol keyboard bawah!",
      );
    }
  }

  // Mesin Otak AI (Mendukung Konteks Waktu, Cuaca, Persona, Bahasa & Emosi Wajah)
  Future<void> _askAiBrain(String userMessage, {bool isSystemTrigger = false}) async {
    _lastInteractionTime = DateTime.now();
    setState(() {
      isThinking = true;
      currentEmotion = PetEmotion.thinking;
      if (!isSystemTrigger) {
        statusSubtitle = "$petName sedang berpikir...";
      }
    });

    // Jika terhubung ke XiaoZhi WS, kirim wake/detect juga ke server XiaoZhi
    if (isXiaoZhiConnected && _xiaozhiWs != null && !isSystemTrigger) {
      try {
        _xiaozhiWs!.add(jsonEncode({
          "type": "listen",
          "state": "detect",
          "text": userMessage,
        }));
      } catch (_) {}
    }

    final langName = languageOptions[selectedLang] ?? "Bahasa Indonesia";
    final systemPrompt = """
Kamu adalah $petName, sebuah AI Pet Robot di layar Android.
Sifat/Personamu: $petPersona.
Konteks Real-Time Saat Ini:
- Jam: $timeString
- Hari/Tanggal: $dateString
- Cuaca & Lokasi: $weatherSummary
- Bahasa Wajib Responmu: $langName

ATURAN PENTING:
1. Jawablah dengan singkat, hidup, ekspresif, dan akrab seperti robot peliharaan sungguhan (maksimal 2 kalimat agar enak didengar).
2. WAJIB awali jawabanmu dengan SATU tag ekspresi wajah di dalam kurung siku dari pilihan ini:
[normal], [happy], [love], [excited], [thinking], [surprised], [sad], [crying], [angry], [sleepy], [wink], [dizzy]
Contoh balasan:
[happy] Halo! Cuaca di $cityName lagi $weatherSummary nih, kamu lagi sibuk apa?
""";

    if (!isSystemTrigger) {
      chatHistory.add({"role": "user", "content": userMessage});
      if (chatHistory.length > 8) chatHistory.removeAt(0);
    }

    String aiReply = "";

    try {
      if (geminiApiKey.trim().isNotEmpty) {
        // Jalur 1: Gemini API jika user mengisi API Key
        final url = Uri.parse(
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${geminiApiKey.trim()}");
        final res = await http
            .post(
              url,
              headers: {"Content-Type": "application/json"},
              body: jsonEncode({
                "systemInstruction": {
                  "parts": [
                    {"text": systemPrompt}
                  ]
                },
                "contents": [
                  {
                    "role": "user",
                    "parts": [
                      {"text": userMessage}
                    ]
                  }
                ]
              }),
            )
            .timeout(const Duration(seconds: 12));

        if (res.statusCode == 200) {
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          aiReply = data['candidates']?[0]?['content']?['parts']?[0]?['text']
                  ?.toString() ??
              "";
        }
      }

      // Jalur 2: Built-in AI Gratis (Tanpa Perlu Akun / Tanpa API Key)
      if (aiReply.trim().isEmpty) {
        final messages = [
          {"role": "system", "content": systemPrompt},
          ...chatHistory,
          if (isSystemTrigger) {"role": "user", "content": userMessage},
        ];

        final res = await http
            .post(
              Uri.parse("https://text.pollinations.ai/openai"),
              headers: {"Content-Type": "application/json"},
              body: jsonEncode({
                "model": "openai",
                "messages": messages,
                "temperature": 0.8,
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (res.statusCode == 200) {
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          aiReply =
              data['choices']?[0]?['message']?['content']?.toString() ?? "";
        }
      }
    } catch (_) {}

    if (aiReply.trim().isEmpty) {
      aiReply =
          "[happy] Halo! Aku $petName. Sekarang jam $timeString dan cuaca $weatherSummary. Senang bisa menemanimu hari ini!";
    }

    setState(() => isThinking = false);
    _processAndSpeakAiReply(aiReply);
  }

  void _processAndSpeakAiReply(String rawReply) {
    PetEmotion detectedEmotion = PetEmotion.happy;
    String cleanText = rawReply.trim();

    final regex = RegExp(r'^\[([a-zA-Z]+)\]\s*');
    final match = regex.firstMatch(cleanText);
    if (match != null) {
      detectedEmotion = _parseEmotionString(match.group(1)!);
      cleanText = cleanText.replaceFirst(regex, '').trim();
    }

    // Bersihkan markdown bintang jika ada
    cleanText = cleanText.replaceAll('*', '');

    chatHistory.add({"role": "assistant", "content": cleanText});
    if (chatHistory.length > 8) chatHistory.removeAt(0);

    if (detectedEmotion == PetEmotion.love) {
      _spawnParticle("❤️", Colors.pinkAccent);
    } else if (detectedEmotion == PetEmotion.excited) {
      _spawnParticle("✨", Colors.amberAccent);
    }

    _speakWithEmotion(detectedEmotion, cleanText);
  }

  PetEmotion _parseEmotionString(String raw) {
    final lower = raw.toLowerCase().trim();
    for (var e in PetEmotion.values) {
      if (e.name == lower) return e;
    }
    if (lower.contains('laugh') || lower.contains('fun')) return PetEmotion.happy;
    if (lower.contains('cool')) return PetEmotion.wink;
    if (lower.contains('shock')) return PetEmotion.surprised;
    return PetEmotion.happy;
  }

  // Inisiatif Mulai Percakapan Duluan (Proactive Engine)
  void _checkProactive() {
    if (!autoProactive || isListening || isThinking || isTalking) return;
    final idleSeconds =
        DateTime.now().difference(_lastInteractionTime).inSeconds;
    if (idleSeconds >= 90) {
      _triggerProactiveGreeting(isInitial: false);
    }
  }

  void _triggerProactiveGreeting({required bool isInitial}) {
    final prompt = isInitial
        ? "[SYSTEM: Aplikasi baru dibuka pada jam $timeString ($dateString) dengan cuaca $weatherSummary. Sapalah pengguna duluan dengan ramah sesuai personamu!]"
        : "[SYSTEM: Pengguna sudah diam cukup lama. Mulailah percakapan duluan secara natural! Kamu bisa membahas waktu sekarang ($timeString), cuaca ($weatherSummary), menanyakan kabar, atau mengajak tebak-tebakan seru!]";
    _askAiBrain(prompt, isSystemTrigger: true);
  }

  void _speakWithEmotion(PetEmotion emotion, String text) async {
    _talkStopTimer?.cancel();
    setState(() {
      currentEmotion = emotion;
      statusSubtitle = text;
      isTalking = true;
    });

    await _tts.stop();
    await _tts.speak(text);

    // Fallback timer untuk animasi mulut jika TTS selesai
    int durationMs = (text.length * 75).clamp(1500, 9000);
    _talkStopTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) setState(() => isTalking = false);
    });
  }

  void _initShakeDetector() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      double gForce =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (gForce > 22.0) {
        final now = DateTime.now();
        if (now.difference(_lastShakeTime).inSeconds > 4) {
          _lastShakeTime = now;
          _spawnParticle("💫", Colors.yellowAccent);
          _askAiBrain(
            "[SYSTEM: Pengguna baru saja menggoyangkan HP dengan kencang sampai kamu pusing! Bereaksilah dengan ekspresi [dizzy]!]",
            isSystemTrigger: true,
          );
        }
      }
    });
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

  void _spawnParticle(String symbol, Color color) {
    final rand = Random();
    setState(() {
      particles.add(
        FloatingParticle(
          position: Offset(
            110 + rand.nextDouble() * 110,
            35 + rand.nextDouble() * 55,
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
    _lastInteractionTime = DateTime.now();
    final local = details.localPosition;
    final centerX = faceAreaSize.width / 2;
    final centerY = faceAreaSize.height / 2;

    final leftEyeCenter = Offset(centerX - 75, centerY - 20);
    final rightEyeCenter = Offset(centerX + 75, centerY - 20);

    if ((local - leftEyeCenter).distance < 45 ||
        (local - rightEyeCenter).distance < 45) {
      _spawnParticle("💢", Colors.redAccent);
      _speakWithEmotion(
        PetEmotion.angry,
        "Aduh! Jangan colok mataku dong, perih tau!",
      );
      return;
    }

    _spawnParticle("✨", Colors.cyanAccent);
    _triggerProactiveGreeting(isInitial: false);
  }

  void _onFacePanUpdate(DragUpdateDetails details, Size faceAreaSize) {
    _lastInteractionTime = DateTime.now();
    final local = details.localPosition;
    final dx = ((local.dx / faceAreaSize.width) - 0.5) * 2.0;
    final dy = ((local.dy / faceAreaSize.height) - 0.5) * 2.0;

    setState(() {
      gazeOffset = Offset(dx.clamp(-1.0, 1.0), dy.clamp(-1.0, 1.0));
    });

    if (dy < -0.15) {
      rubCounter++;
      if (rubCounter % 14 == 0) {
        _spawnParticle("❤️", Colors.pinkAccent);
        if (currentEmotion != PetEmotion.love) {
          _speakWithEmotion(
            PetEmotion.love,
            "Hehe, nyaman banget dielus-elus sama kamu!",
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
    _proactiveTimer?.cancel();
    _talkStopTimer?.cancel();
    _accelSub?.cancel();
    _xiaozhiWs?.close();
    _tts.stop();
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
            // HUD Bar Atas (Nama, Cuaca, Jam, Tombol Pairing & Settings)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                        onPressed: _toggleOrientation,
                      ),
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: isXiaoZhiConnected
                              ? Colors.greenAccent
                              : baseColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: baseColor, blurRadius: 6)
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            petName.toUpperCase(),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                              color: baseColor,
                            ),
                          ),
                          Text(
                            weatherSummary,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white60,
                            ),
                          ),
                        ],
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
                          fontSize: 10,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.qr_code_2,
                            color: Colors.cyanAccent),
                        tooltip: "Pairing XiaoZhi 6-Digit",
                        onPressed: _checkXiaoZhiOtaPairing,
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings, color: Colors.white70),
                        onPressed: _showSettingsDialog,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Area Wajah Robot Interaktif
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
                                size: const Size(320, 210),
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
                        ...particles.map(
                          (p) => Positioned(
                            left: (size.width / 2 - 160) + p.position.dx,
                            top: (size.height / 2 - 105) + p.position.dy,
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

            // Kotak Subtitle Obrolan AI
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isListening
                        ? Colors.redAccent
                        : baseColor.withOpacity(0.35),
                    width: isListening ? 2 : 1,
                  ),
                ),
                child: Text(
                  statusSubtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                ),
              ),
            ),

            // Panel Kontrol Suara, Ketik Pesan, & Sapa Duluan
            Padding(
              padding: const EdgeInsets.only(bottom: 14, left: 20, right: 20, top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Tombol Ketik Teks
                  IconButton.filledTonal(
                    onPressed: _showTextInputDialog,
                    icon: const Icon(Icons.keyboard),
                    tooltip: "Ketik Pesan",
                  ),
                  const SizedBox(width: 18),

                  // Tombol Utama Mikrofon (Bicara)
                  GestureDetector(
                    onTap: _toggleListening,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: isListening ? 72 : 64,
                      height: isListening ? 72 : 64,
                      decoration: BoxDecoration(
                        color: isListening ? Colors.redAccent : baseColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (isListening ? Colors.redAccent : baseColor)
                                .withOpacity(0.5),
                            blurRadius: 16,
                            spreadRadius: 2,
                          )
                        ],
                      ),
                      child: Icon(
                        isListening ? Icons.mic : Icons.mic_none,
                        color: Colors.black,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),

                  // Tombol Pancing Pet Ngobrol Duluan
                  IconButton.filledTonal(
                    onPressed: () =>
                        _triggerProactiveGreeting(isInitial: false),
                    icon: const Icon(Icons.bolt, color: Colors.amberAccent),
                    tooltip: "Minta Pet Mulai Ngobrol",
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTextInputDialog() {
    final textCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Ngobrol dengan $petName"),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "Ketik pertanyaan atau ajak ngobrol...",
          ),
          onSubmitted: (val) {
            if (val.trim().isNotEmpty) {
              Navigator.pop(context);
              _askAiBrain(val.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Batal"),
          ),
          ElevatedButton(
            onPressed: () {
              if (textCtrl.text.trim().isNotEmpty) {
                Navigator.pop(context);
                _askAiBrain(textCtrl.text.trim());
              }
            },
            child: const Text("Kirim"),
          ),
        ],
      ),
    );
  }

  void _showPairingDialog(String code, String? serverMsg) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("🔗 Kode Pairing XiaoZhi"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Masukkan 6 angka ini di menu Add Device pada dashboard xiaozhi.me:",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.cyanAccent),
              ),
              child: Text(
                code,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 8,
                  color: Colors.cyanAccent,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "MAC Address Virtual:\n$deviceMac",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
            if (serverMsg != null) ...[
              const SizedBox(height: 8),
              Text(
                serverMsg,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.amberAccent),
              ),
            ],
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Selesai"),
          ),
        ],
      ),
    );
  }

  void _showSettingsDialog() {
    final nameCtrl = TextEditingController(text: petName);
    final personaCtrl = TextEditingController(text: petPersona);
    final urlCtrl = TextEditingController(text: xiaozhiUrl);
    final keyCtrl = TextEditingController(text: geminiApiKey);
    int selectedColor = themeColorIndex;
    String tempLang = selectedLang;
    bool tempProactive = autoProactive;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Pengaturan AI, Bahasa & Persona"),
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
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: tempLang,
                  decoration: const InputDecoration(
                    labelText: "Bahasa Respon & Suara AI",
                  ),
                  items: languageOptions.entries
                      .map((e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value,
                                style: const TextStyle(fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) setDialogState(() => tempLang = val);
                  },
                ),
                const SizedBox(height: 10),
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
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Inisiatif Ngobrol Duluan",
                      style: TextStyle(fontSize: 13)),
                  subtitle: const Text("Pet menyapa otomatis saat kamu diam",
                      style: TextStyle(fontSize: 11)),
                  value: tempProactive,
                  onChanged: (v) => setDialogState(() => tempProactive = v),
                ),
                const Divider(),
                Text(
                  "Device MAC (XiaoZhi): $deviceMac",
                  style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
                ),
                const SizedBox(height: 6),
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
                    labelText: "Gemini API Key (Opsional)",
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
                  name: nameCtrl.text,
                  persona: personaCtrl.text,
                  lang: tempLang,
                  url: urlCtrl.text,
                  apiKey: keyCtrl.text,
                  colorIdx: selectedColor,
                  proactive: tempProactive,
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
    final leftCenter =
        Offset(size.width * 0.26, size.height * 0.42) + gazeShift;
    final rightCenter =
        Offset(size.width * 0.74, size.height * 0.42) + gazeShift;

    _drawCustomEye(
        canvas, leftCenter, eyeWidth, eyeHeight, paint, glowPaint, true);
    _drawCustomEye(
        canvas, rightCenter, eyeWidth, eyeHeight, paint, glowPaint, false);

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
      double r = 24;
      canvas.drawLine(
          center.translate(-r, -r), center.translate(r, r), strokePaint);
      canvas.drawLine(
          center.translate(r, -r), center.translate(-r, r), strokePaint);
      return;
    }

    if (emotion == PetEmotion.love) {
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
    final mouthCenter = Offset(size.width * 0.5, size.height * 0.78) + shift;
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

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
