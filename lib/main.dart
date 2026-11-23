import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

// ============================================================
//  কৃষি সেবা
//  ট্যাব ১: AI রোগ নির্ণয়  |  ট্যাব ২: সরকারি ক্রয়মূল্য ও হিসাব  |  ট্যাব ৩: সহায়তা
// ============================================================

// API কী কোডের ভেতরে লিখবেন না। চালানোর সময় দিন:
// flutter run -d edge --dart-define-from-file=env.json
const String kApiKey = String.fromEnvironment('GEMINI_API_KEY');

// সরকারি ক্রয়মূল্যের অনলাইন ফাইলের ঠিকানা (prices.json)। env.json-এ দিন:
// {"GEMINI_API_KEY": "...", "PRICES_URL": "https://raw.githubusercontent.com/আপনার-নাম/রিপো/main/prices.json"}
// খালি থাকলে বা নেট না থাকলে অ্যাপে রাখা তথ্য দেখায়।
const String kPricesUrl = String.fromEnvironment('PRICES_URL');

// একটা মডেল ব্যস্ত থাকলে অ্যাপ নিজে পরেরটা চেষ্টা করবে।
// কোনো নাম কাজ না করলে (404) এই তালিকা ঠিক করুন।
const List<String> kModels = [
  'gemini-flash-latest',
  'gemini-3.8-flash',
  'gemini-flash-lite-latest',
];

// মোট কতবার চেষ্টা করবে (প্রতিবার তালিকার পরের মডেলে ঘুরে ঘুরে)
const int kMaxAttempts = 6;

// প্রতিটি চেষ্টায় সর্বোচ্চ কতক্ষণ অপেক্ষা করবে
const Duration kRequestTimeout = Duration(seconds: 45);

const String kPrompt = '''
তুমি একজন অভিজ্ঞ কৃষি বিশেষজ্ঞ। এই ছবিতে একটি ফসল বা গাছের পাতা/ফল আছে।
সহজ বাংলায়, কৃষক বুঝতে পারে এমনভাবে নিচের ক্রমে উত্তর দাও:

১. ফসলের নাম
২. সম্ভাব্য রোগ বা সমস্যা (নিশ্চিত না হলে "সম্ভাব্য" বলো)
৩. লক্ষণ (ছবিতে কী দেখা যাচ্ছে)
৪. কারণ
৫. প্রতিকার (জৈব উপায় আগে, তারপর প্রয়োজনে রাসায়নিক)
৬. ভবিষ্যতে প্রতিরোধের উপায়

উত্তরে কোনো মার্কডাউন চিহ্ন (যেমন ** বা * বা #) ব্যবহার করবে না, শুধু সাধারণ লেখা। তালিকার জন্য "-" ব্যবহার করো।
ছবি স্পষ্ট না হলে বা গাছের ছবি না হলে সেটা বলো। শেষে এক লাইনে লেখো:
"নিশ্চিত হতে স্থানীয় উপজেলা কৃষি অফিসারের পরামর্শ নিন।"
''';

// ---------- রঙ ----------
const Color kGreenDark = Color(0xFF1B5E20);
const Color kGreen = Color(0xFF2E7D32);
const Color kGreenLight = Color(0xFF66BB6A);
const Color kGold = Color(0xFFFFC107);
const Color kBg = Color(0xFFF6F9F2);

// ============================================================
//  সরকারি ক্রয়মূল্যের তথ্য
//  দাম প্রতি মৌসুমে বদলায়। বদলালে শুধু এই অংশটা ঠিক করুন।
// ============================================================
const String kDataUpdated = 'তথ্য হালনাগাদ: ১৬ নভেম্বর ২০২৬';

class PriceRow {
  final String item;
  final String price;
  const PriceRow(this.item, this.price);

  factory PriceRow.fromJson(Map<String, dynamic> j) =>
      PriceRow(j['item'].toString(), j['price'].toString());
}

Color _hexColor(String s) =>
    Color(int.parse('FF${s.replaceAll('#', '')}', radix: 16));

class PriceSection {
  final String title;
  final String badge;
  final Color color;
  final List<PriceRow> rows;
  final List<String> notes;
  const PriceSection({
    required this.title,
    required this.badge,
    required this.color,
    required this.rows,
    required this.notes,
  });

  factory PriceSection.fromJson(Map<String, dynamic> j) => PriceSection(
        title: j['title'].toString(),
        badge: j['badge'].toString(),
        color: _hexColor(j['color'].toString()),
        rows: (j['rows'] as List)
            .map((e) => PriceRow.fromJson(e as Map<String, dynamic>))
            .toList(),
        notes: ((j['notes'] ?? []) as List).map((e) => e.toString()).toList(),
      );
}

const List<PriceSection> kSections = [
  PriceSection(
    title: 'আমন মৌসুম ২০২৬-২৭',
    badge: 'চলমান',
    color: kGreen,
    rows: [
      PriceRow('আমন ধান', '৩৫ টাকা / কেজি'),
      PriceRow('সিদ্ধ চাল', '৪৯ টাকা / কেজি'),
      PriceRow('আতপ চাল', '৪৮ টাকা / কেজি'),
    ],
    notes: [
      'ধান সংগ্রহ: ১৪ নভেম্বর ২০২৬ থেকে ২৮ ফেব্রুয়ারি ২০২৭',
      'চাল সংগ্রহ: ১ ডিসেম্বর ২০২৬ থেকে ২৮ ফেব্রুয়ারি ২০২৭',
      'লক্ষ্যমাত্রা: ৩ লাখ টন ধান, ৫ লাখ টন সিদ্ধ চাল, ৫০ হাজার টন আতপ চাল',
    ],
  ),
  PriceSection(
    title: 'আখ (নর্থ বেঙ্গল চিনিকল, ২০২৬-২৭)',
    badge: 'চলমান',
    color: Color(0xFF8D6E00),
    rows: [
      PriceRow('চিনিকলের গেটে', '৬৫১ টাকা / কুইন্টাল'),
      PriceRow('আখ সংগ্রহ কেন্দ্রে', '৬৩৭.৪৬ টাকা / কুইন্টাল'),
    ],
    notes: [
      '১ কুইন্টাল = ১০০ কেজি',
      'আখের দাম চিনিকলভেদে আলাদা হয়। নিজের এলাকার চিনিকল থেকে জেনে নিন।',
    ],
  ),
  PriceSection(
    title: 'বোরো মৌসুম ২০২৬',
    badge: 'শেষ হয়েছে',
    color: Color(0xFF546E7A),
    rows: [
      PriceRow('বোরো ধান', '৩৬ টাকা / কেজি'),
      PriceRow('সিদ্ধ চাল', '৪৯ টাকা / কেজি'),
      PriceRow('আতপ চাল', '৪৮ টাকা / কেজি'),
      PriceRow('গম', '৩৬ টাকা / কেজি'),
    ],
    notes: [
      'সংগ্রহ চলেছে ৩১ আগস্ট ২০২৬ পর্যন্ত। পরের বোরো মৌসুমের দাম সাধারণত এপ্রিলে ঘোষণা হয়।',
    ],
  ),
  PriceSection(
    title: 'পাট',
    badge: 'বাজারদর',
    color: Color(0xFF6D4C41),
    rows: [
      PriceRow('কাঁচা পাট (আগস্ট ২০২৬, নড়াইল ও রাজশাহী)', '৩,২০০ - ৩,৬০০ টাকা / মণ'),
    ],
    notes: [
      'এটা সরকার-ঘোষিত দাম নয়, হাটের বাজারদর। জুন ২০২৬-এর একটি প্রতিবেদনে কৃষকেরা সরকার-ঘোষিত ন্যূনতম মূল্য না থাকার কথা বলেছেন।',
      'পাটের দাম হাট ও মানভেদে দ্রুত বদলায়।',
    ],
  ),
];

class CalcItem {
  final String name;
  final double pricePerKg;
  const CalcItem(this.name, this.pricePerKg);

  factory CalcItem.fromJson(Map<String, dynamic> j) => CalcItem(
        j['name'].toString(),
        double.parse(j['pricePerKg'].toString()),
      );
}

/// দামের পুরো তথ্য: অনলাইন ফাইল থেকে আসে, না এলে অ্যাপের ভেতরের তথ্য
class PriceData {
  final List<PriceSection> sections;
  final List<CalcItem> calcItems;
  final String updated;
  const PriceData(this.sections, this.calcItems, this.updated);

  static const PriceData builtIn =
      PriceData(kSections, kCalcItems, '১৬ নভেম্বর ২০২৬');

  factory PriceData.fromJson(Map<String, dynamic> j) {
    final secs = (j['sections'] as List)
        .map((e) => PriceSection.fromJson(e as Map<String, dynamic>))
        .toList();
    final calc = (j['calc'] as List)
        .map((e) => CalcItem.fromJson(e as Map<String, dynamic>))
        .toList();
    if (secs.isEmpty || calc.isEmpty) throw const FormatException('empty');
    return PriceData(secs, calc, (j['updated'] ?? '').toString());
  }
}

const List<CalcItem> kCalcItems = [
  CalcItem('আমন ধান (৩৫ টাকা)', 35),
  CalcItem('সিদ্ধ চাল (৪৯ টাকা)', 49),
  CalcItem('আতপ চাল (৪৮ টাকা)', 48),
  CalcItem('আখ, চিনিকলের গেটে (৬.৫১ টাকা)', 6.51),
];

// ---------- বাংলা সংখ্যা সহায়ক ----------
const String _bnDigits = '০১২৩৪৫৬৭৮৯';

String toBn(String s) {
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final d = int.tryParse(ch);
    b.write(d == null ? ch : _bnDigits[d]);
  }
  return b.toString();
}

String toEn(String s) {
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = _bnDigits.indexOf(ch);
    b.write(i >= 0 ? '$i' : ch);
  }
  return b.toString();
}

/// ১২৩৪৫৬.৭ -> "১,২৩,৪৫৭" (বাংলাদেশি কমা ধরনে)
String formatTaka(double v) {
  final n = v.round().toString();
  if (n.length <= 3) return toBn(n);
  final last3 = n.substring(n.length - 3);
  var rest = n.substring(0, n.length - 3);
  final parts = <String>[];
  while (rest.length > 2) {
    parts.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) parts.insert(0, rest);
  return toBn('${parts.join(',')},$last3');
}

// ============================================================
//  লোগো (কোড দিয়ে আঁকা, কোনো ছবির ফাইল লাগে না)
// ============================================================
class LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;

    final bg = Paint()
      ..shader = const LinearGradient(
        colors: [kGreenDark, kGreenLight],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Rect.fromLTWH(0, 0, s, s));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, s, s),
        Radius.circular(s * 0.24),
      ),
      bg,
    );

    // সোনালি মাটি/সূর্য
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(s * 0.5, s * 0.80),
        width: s * 0.56,
        height: s * 0.22,
      ),
      math.pi,
      math.pi,
      true,
      Paint()..color = kGold,
    );

    // কাণ্ড
    canvas.drawLine(
      Offset(s * 0.5, s * 0.79),
      Offset(s * 0.5, s * 0.42),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.05
        ..strokeCap = StrokeCap.round,
    );

    final white = Paint()..color = Colors.white;

    final left = Path()
      ..moveTo(s * 0.50, s * 0.55)
      ..cubicTo(s * 0.25, s * 0.55, s * 0.20, s * 0.35, s * 0.25, s * 0.28)
      ..cubicTo(s * 0.45, s * 0.28, s * 0.52, s * 0.40, s * 0.50, s * 0.55)
      ..close();
    canvas.drawPath(left, white);

    final right = Path()
      ..moveTo(s * 0.50, s * 0.45)
      ..cubicTo(s * 0.72, s * 0.45, s * 0.80, s * 0.28, s * 0.76, s * 0.20)
      ..cubicTo(s * 0.55, s * 0.20, s * 0.48, s * 0.32, s * 0.50, s * 0.45)
      ..close();
    canvas.drawPath(right, white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class KrishiLogo extends StatelessWidget {
  final double size;
  const KrishiLogo({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: LogoPainter()),
    );
  }
}

// ============================================================
//  অ্যাপ
// ============================================================
void main() {
  runApp(const KrishiSebaApp());
}

class KrishiSebaApp extends StatelessWidget {
  const KrishiSebaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'কৃষি সেবা',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: kGreen,
        scaffoldBackgroundColor: kBg,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 12,
        title: Row(
          children: [
            const KrishiLogo(size: 38),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'কৃষি সেবা',
                  style: TextStyle(
                    color: kGreen,
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                ),
                Text(
                  'Success 2026',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          DiagnosePage(),
          ProcurementPage(),
          HelpPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.psychology_outlined),
            selectedIcon: Icon(Icons.psychology),
            label: 'রোগ নির্ণয়',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_outlined),
            selectedIcon: Icon(Icons.account_balance),
            label: 'সরকারি ক্রয়',
          ),
          NavigationDestination(
            icon: Icon(Icons.support_agent_outlined),
            selectedIcon: Icon(Icons.support_agent),
            label: 'সহায়তা',
          ),
        ],
      ),
    );
  }
}

// ============================================================
//  ট্যাব ১: AI রোগ নির্ণয়
// ============================================================
class DiagnosePage extends StatefulWidget {
  const DiagnosePage({super.key});

  @override
  State<DiagnosePage> createState() => _DiagnosePageState();
}

class _DiagnosePageState extends State<DiagnosePage> {
  final ImagePicker _picker = ImagePicker();

  Uint8List? _imageBytes;
  String _mimeType = 'image/jpeg';
  bool _loading = false;
  String _status = 'AI ছবিটি বিশ্লেষণ করছে...';
  String? _result;
  String? _error;

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 800,
        imageQuality: 70,
      );
      if (picked == null) return; // ব্যবহারকারী বাতিল করেছে

      final bytes = await picked.readAsBytes();
      setState(() {
        _imageBytes = bytes;
        _mimeType = picked.mimeType ?? 'image/jpeg';
        _result = null;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'ছবি নিতে সমস্যা হয়েছে: $e');
    }
  }

  /// AI-র উত্তরে থাকা মার্কডাউন চিহ্ন (**, *, #) সরিয়ে পরিষ্কার লেখা বানায়।
  String _cleanText(String input) {
    var t = input.replaceAll('**', '');
    t = t.replaceAll(RegExp(r'^\s*[\*\-]\s+', multiLine: true), '• ');
    t = t.replaceAll(RegExp(r'^#+\s*', multiLine: true), '');
    t = t.replaceAll(RegExp(r'(?<!\w)\*(?!\s)([^*\n]+)\*'), r'$1');
    return t.trim();
  }

  /// Gemini-কে কল করে। ব্যস্ত (503/429) বা সময় শেষ হলে নিজে আবার
  /// চেষ্টা করে এবং পরের মডেলে যায়। কী ভুল (400/403) হলে সাথে সাথে থামে।
  Future<String> _callGemini() async {
    String lastError = 'অজানা সমস্যা';
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': kPrompt},
            {
              'inline_data': {
                'mime_type': _mimeType,
                'data': base64Encode(_imageBytes!),
              }
            },
          ],
        }
      ],
      'generationConfig': {'temperature': 0.3},
    });

    for (int attempt = 0; attempt < kMaxAttempts; attempt++) {
      final model = kModels[attempt % kModels.length];

      if (attempt > 0) {
        if (mounted) {
          setState(() => _status =
              'সার্ভার ব্যস্ত, আবার চেষ্টা করা হচ্ছে (${attempt + 1}/$kMaxAttempts)...');
        }
        await Future.delayed(Duration(seconds: 2 * attempt));
      }

      try {
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
        );

        final response = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': kApiKey,
              },
              body: body,
            )
            .timeout(kRequestTimeout);

        final data = jsonDecode(utf8.decode(response.bodyBytes));

        if (response.statusCode == 200) {
          final text =
              data['candidates']?[0]?['content']?['parts']?[0]?['text'];
          if (text != null) return _cleanText(text as String);
          lastError =
              'AI কোনো উত্তর দেয়নি। অন্য একটি স্পষ্ট ছবি দিয়ে চেষ্টা করুন।';
          continue;
        }

        final msg = data['error']?['message'] ?? 'অজানা সমস্যা';
        lastError = 'সার্ভার এরর (${response.statusCode}): $msg';

        // সাময়িক সমস্যা বা মডেলের নাম অচল: আবার চেষ্টা / পরের মডেল
        if ([404, 429, 500, 502, 503, 504].contains(response.statusCode)) {
          continue;
        }

        // 400/403 ইত্যাদি (কী ভুল, ইত্যাদি): আবার চেষ্টা করে লাভ নেই
        throw lastError;
      } on TimeoutException {
        lastError = 'সময় শেষ: সার্ভার থেকে উত্তর আসেনি।';
      } on http.ClientException catch (e) {
        lastError = 'নেটওয়ার্ক সমস্যা: ${e.message}';
      } on FormatException {
        lastError = 'সার্ভার থেকে অপ্রত্যাশিত উত্তর এসেছে।';
      }
    }

    throw '$lastError\n(মোট $kMaxAttempts বার চেষ্টা করা হয়েছে, কিছুক্ষণ পর আবার চেষ্টা করুন)';
  }

  Future<void> _diagnose() async {
    if (_imageBytes == null) return;

    if (kApiKey.isEmpty) {
      setState(() => _error =
          'API কী দেওয়া হয়নি। অ্যাপ চালান:\nflutter run -d edge --dart-define-from-file=env.json');
      return;
    }

    setState(() {
      _loading = true;
      _status = 'AI ছবিটি বিশ্লেষণ করছে...';
      _result = null;
      _error = null;
    });

    try {
      final text = await _callGemini();
      setState(() => _result = text);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ছবি দেখানোর জায়গা
          Container(
            height: 240,
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: _imageBytes == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        KrishiLogo(size: 84),
                        SizedBox(height: 10),
                        Text(
                          'রোগাক্রান্ত পাতা বা ফসলের ছবি দিন',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ],
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.memory(_imageBytes!, fit: BoxFit.cover),
                  ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed:
                      _loading ? null : () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('ছবি তুলুন'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed:
                      _loading ? null : () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.image),
                  label: const Text('গ্যালারি'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          ElevatedButton.icon(
            onPressed: (_imageBytes == null || _loading) ? null : _diagnose,
            icon: const Icon(Icons.psychology),
            label: const Text('রোগ নির্ণয় করুন (AI)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 20),

          if (_loading)
            Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 10),
                Text(_status, textAlign: TextAlign.center),
              ],
            ),

          if (_error != null)
            Card(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  _error!,
                  style: TextStyle(color: Colors.red.shade800),
                ),
              ),
            ),

          if (_result != null)
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'রোগ নির্ণয়ের ফলাফল',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: kGreen,
                      ),
                    ),
                    const Divider(),
                    SelectableText(
                      _result!,
                      style: const TextStyle(fontSize: 16, height: 1.5),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================
//  ট্যাব ২: সরকারি ক্রয়মূল্য ও দামের হিসাব
// ============================================================
class ProcurementPage extends StatefulWidget {
  const ProcurementPage({super.key});

  @override
  State<ProcurementPage> createState() => _ProcurementPageState();
}

class _ProcurementPageState extends State<ProcurementPage> {
  PriceData _data = PriceData.builtIn;
  bool _online = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// অনলাইন prices.json থেকে নতুন দাম আনে। ব্যর্থ হলে আগের তথ্য থাকে।
  Future<void> _load() async {
    if (kPricesUrl.isEmpty) return;
    setState(() => _loading = true);
    try {
      final uri = Uri.parse(
          '$kPricesUrl?t=${DateTime.now().millisecondsSinceEpoch}');
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw 'status ${r.statusCode}';
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final d = PriceData.fromJson(j);
      if (mounted) {
        setState(() {
          _data = d;
          _online = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _online = false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _statusText {
    if (kPricesUrl.isEmpty) {
      return 'তথ্য হালনাগাদ: ${_data.updated} (অ্যাপে রাখা তথ্য)';
    }
    if (_online) return 'অনলাইন থেকে হালনাগাদ: ${_data.updated}';
    return 'নেট থেকে আনা যায়নি, অ্যাপে রাখা তথ্য: ${_data.updated}';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'সরকার কৃষকের কাছ থেকে যা কেনে',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: kGreenDark,
                ),
              ),
            ),
            if (kPricesUrl.isNotEmpty)
              _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      tooltip: 'নতুন দাম আনুন',
                    ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _statusText,
          style: const TextStyle(color: Colors.black54, fontSize: 13),
        ),
        const SizedBox(height: 12),

        for (final s in _data.sections) _SectionCard(section: s),

        _Calculator(items: _data.calcItems),
        const SizedBox(height: 12),

        // কীভাবে বিক্রি করবেন
        Card(
          color: Colors.amber.shade50,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'সরকারের কাছে বিক্রি করতে চাইলে',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                SizedBox(height: 6),
                Text(
                  '- সংগ্রহের সময়ের মধ্যে নিজের উপজেলা খাদ্য কর্মকর্তার অফিসে যোগাযোগ করুন।\n'
                  '- ধান সরবরাহের জন্য নির্ধারিত সময়ের মধ্যে নিবন্ধন করতে হয়।\n'
                  '- কোন গুদামে কবে দিতে হবে, কত পরিমাণ নেওয়া হবে, তা স্থানীয় অফিস থেকে জেনে নিন।',
                  style: TextStyle(height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'দাম ও সময়সূচি সরকারি সিদ্ধান্তে বদলাতে পারে। সংবাদ প্রতিবেদন (যুগান্তর, '
          'দ্য ফাইন্যান্সিয়াল এক্সপ্রেস, বাংলা ট্রিবিউন, রাইজিংবিডি, ঢাকা ট্রিবিউন) থেকে নেওয়া তথ্য। '
          'বিক্রির আগে স্থানীয় খাদ্য বা কৃষি অফিস থেকে নিশ্চিত হোন।',
          style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final PriceSection section;
  const _SectionCard({required this.section});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.5,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            color: section.color,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    section.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    section.badge,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Column(
              children: [
                for (final r in section.rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Text(r.item,
                              style: const TextStyle(fontSize: 15)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 4,
                          child: Text(
                            r.price,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: section.color,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final n in section.notes)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '• $n',
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// দামের হিসাব: কত কেজি বা মণ দিলে সরকারি দরে কত টাকা হবে
class _Calculator extends StatefulWidget {
  final List<CalcItem> items;
  const _Calculator({required this.items});

  @override
  State<_Calculator> createState() => _CalculatorState();
}

class _CalculatorState extends State<_Calculator> {
  final TextEditingController _ctrl = TextEditingController();
  int _item = 0;
  bool _maund = true; // true হলে মণ (১ মণ = ৪০ কেজি), নইলে কেজি

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double? get _qty {
    final v = double.tryParse(toEn(_ctrl.text.trim()));
    return (v == null || v < 0) ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final sel = _item.clamp(0, items.length - 1).toInt();
    final item = items[sel];
    final qty = _qty;
    final kg = qty == null ? null : (_maund ? qty * 40 : qty);
    final total = kg == null ? null : kg * item.pricePerKg;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.calculate, color: kGreen),
                SizedBox(width: 8),
                Text(
                  'দামের হিসাব',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'কত ফসল দিলে সরকারি দরে কত টাকা পাবেন',
              style: TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: sel,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'ফসল',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (int i = 0; i < items.length; i++)
                  DropdownMenuItem(value: i, child: Text(items[i].name)),
              ],
              onChanged: (v) => setState(() => _item = v ?? 0),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'পরিমাণ',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('মণ')),
                    ButtonSegment(value: false, label: Text('কেজি')),
                  ],
                  selected: {_maund},
                  onSelectionChanged: (s) => setState(() => _maund = s.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: total == null
                  ? const Text(
                      'পরিমাণ লিখুন',
                      style: TextStyle(color: Colors.black54),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${formatTaka(kg!)} কেজি × ${toBn(item.pricePerKg.toString())} টাকা',
                          style: const TextStyle(color: Colors.black54),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '৳ ${formatTaka(total)}',
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: kGreenDark,
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 6),
            const Text(
              '১ মণ = ৪০ কেজি ধরা হয়েছে। এটা শুধু আনুমানিক হিসাব, আর্দ্রতা ও মান অনুযায়ী প্রাপ্য বদলাতে পারে।',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
//  ট্যাব ৩: সহায়তা
// ============================================================
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'সহায়তা ও যোগাযোগ',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: kGreenDark,
          ),
        ),
        const SizedBox(height: 12),

        // কৃষি কল সেন্টার
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.phone_in_talk, color: kGreen),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'কৃষি কল সেন্টার',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'যেকোনো মোবাইল থেকে কল করে কৃষি, মৎস্য ও প্রাণিসম্পদ বিশেষজ্ঞের পরামর্শ পাওয়া যায়। '
                  'কৃষি তথ্য সার্ভিস (কৃষি মন্ত্রণালয়) এই সেবা চালায়।',
                  style: TextStyle(height: 1.5),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      '১৬১২৩',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: kGreenDark,
                        letterSpacing: 2,
                      ),
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                            const ClipboardData(text: '16123'));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content:
                                  Text('নম্বর কপি হয়েছে, ফোনের ডায়ালারে বসিয়ে কল করুন'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('নম্বর কপি'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        _TipCard(
          icon: Icons.photo_camera,
          title: 'ভালো ছবি তোলার নিয়ম',
          lines: const [
            'দিনের আলোয় ছবি তুলুন।',
            'রোগাক্রান্ত পাতা বা অংশ কাছ থেকে পরিষ্কার দেখান।',
            'একটা ছবিতে একটা ফসলের পাতা রাখুন।',
            'সম্ভব হলে সুস্থ পাতার পাশে রোগাক্রান্ত পাতার ছবিও তুলুন।',
          ],
        ),
        _TipCard(
          icon: Icons.warning_amber,
          title: 'AI-র উত্তর নিয়ে সতর্কতা',
          lines: const [
            'AI ছবি দেখে সম্ভাব্য রোগ অনুমান করে, ১০০% নিশ্চিত নয়।',
            'কীটনাশক বা ছত্রাকনাশক দেওয়ার আগে উপজেলা কৃষি অফিসার বা কৃষি কল সেন্টারের পরামর্শ নিন।',
            'ওষুধের প্যাকেটের নির্দেশনা ও মাত্রা মেনে চলুন।',
          ],
        ),
        _TipCard(
          icon: Icons.store,
          title: 'নিজের এলাকার অফিস',
          lines: const [
            'উপজেলা কৃষি অফিস: ফসলের রোগ, সার, বীজ ও প্রশিক্ষণ।',
            'উপজেলা খাদ্য কর্মকর্তার অফিস: ধান ও চাল সরকারের কাছে বিক্রি।',
            'চিনিকল ও পাট কেন্দ্র: আখ ও পাটের দাম ও সংগ্রহ।',
          ],
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'কৃষি সেবা  •  Success 2026',
            style: TextStyle(color: Colors.black45, fontSize: 12),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _TipCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<String> lines;
  const _TipCard({
    required this.icon,
    required this.title,
    required this.lines,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      elevation: 1.5,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: kGreen),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $l', style: const TextStyle(height: 1.45)),
              ),
          ],
        ),
      ),
    );
  }
}
