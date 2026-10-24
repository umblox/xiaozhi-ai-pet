import 'package:flutter/material.dart';

// 23 Ekspresi Lengkap ala Robot EMO + State Dead (Shoot & Die)
enum XiaoZhiEmotion {
  neutral,
  happy,
  laughing,
  funny,
  sad,
  angry,
  crying,
  loving,
  embarrassed,
  surprised,
  shocked,
  thinking,
  winking,
  cool,
  relaxed,
  delicious,
  kissy,
  confident,
  sleepy,
  silly,
  confused,
  dizzy,
  dead,
}

// Gestur Tangan & Jari Ekspresif
enum HandGesture {
  none,
  wave,
  peace,
  thumbsUp,
  thinkingChin,
  angryFists,
  handsUp,
  coverCheeks,
  highFive,
  deadDrop,
}

// 4 Mode Musisi Konser YouTube
enum MusicianMode {
  none,
  dj,
  guitar,
  piano,
  vocal,
}

// Status Sesi Interaksi Suara
enum SessionState {
  standbyVad,
  listeningToUser,
  speakingTts,
}

// Model Partikel Efek Melayang (Hati, Musik, Bintang, Zzz)
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

// Palet Warna Neon Utama
const List<Color> kPetThemeColors = [
  Colors.cyanAccent,
  Colors.pinkAccent,
  Colors.greenAccent,
  Colors.amberAccent,
  Colors.purpleAccent,
];

// Pemetaan Nama Emosi dari Server XiaoZhi ke Enum Lokal
XiaoZhiEmotion mapXiaoZhiEmotion(String emo) {
  final clean = emo.toLowerCase().trim();
  for (final val in XiaoZhiEmotion.values) {
    if (val.name == clean) return val;
  }
  return XiaoZhiEmotion.neutral;
}

// Pemetaan Gestur Tangan Default untuk Setiap Emosi
HandGesture defaultGestureForEmotion(XiaoZhiEmotion emo) {
  switch (emo) {
    case XiaoZhiEmotion.happy:
      return HandGesture.wave;
    case XiaoZhiEmotion.winking:
    case XiaoZhiEmotion.silly:
    case XiaoZhiEmotion.funny:
    case XiaoZhiEmotion.laughing:
      return HandGesture.peace;
    case XiaoZhiEmotion.cool:
    case XiaoZhiEmotion.confident:
      return HandGesture.thumbsUp;
    case XiaoZhiEmotion.thinking:
    case XiaoZhiEmotion.confused:
      return HandGesture.thinkingChin;
    case XiaoZhiEmotion.angry:
      return HandGesture.angryFists;
    case XiaoZhiEmotion.embarrassed:
    case XiaoZhiEmotion.loving:
    case XiaoZhiEmotion.kissy:
      return HandGesture.coverCheeks;
    case XiaoZhiEmotion.shocked:
    case XiaoZhiEmotion.surprised:
      return HandGesture.handsUp;
    case XiaoZhiEmotion.dead:
      return HandGesture.deadDrop;
    default:
      return HandGesture.none;
  }
}
