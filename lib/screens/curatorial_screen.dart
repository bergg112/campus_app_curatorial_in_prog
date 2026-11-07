import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// Konfiguration
// ---------------------------------------------------------------------------

/// Adresse deines Cloudflare Workers (ohne "/" am Ende).
/// TODO: nach dem Deploy hier eintragen.
const String kCuratorialApi = 'https://curatorial-upload.berg-thoos.workers.dev';

const _kAccent = Color(0xFF3B82F6);
const _kBg = Color(0xFF0E1420);
const _kCard = Color(0xFF151D2E);
const _kCardLight = Color(0xFF1C2638);
const _kMuted = Color(0xFF8A93A6);
const _kMaxCaption = 100;
const _kMaxBytes = 2 * 1024 * 1024; // muss zum Worker passen

// ---------------------------------------------------------------------------
// API-Hilfen
// ---------------------------------------------------------------------------

class _Post {
  final String id;
  final String caption;
  final String imageUrl;
  final String status; // approved | pending | rejected
  _Post({required this.id, required this.caption, required this.imageUrl, this.status = 'approved'});

  factory _Post.fromJson(Map<String, dynamic> j) => _Post(
        id: j['id'] as String,
        caption: (j['caption'] ?? '') as String,
        imageUrl: j['imageUrl'] as String,
        status: (j['status'] ?? 'approved') as String,
      );
}

class _Api {
  static Uri _u(String path, [Map<String, String>? q]) => Uri.parse('$kCuratorialApi$path').replace(queryParameters: q);

  static Map<String, String> _auth(String pw) => {'Authorization': 'Bearer $pw'};

  static Future<List<_Post>> feed({required DateTime since}) async {
    final res = await http
        .get(_u('/posts', {'since': since.millisecondsSinceEpoch.toString()}))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw 'Serverfehler (${res.statusCode})';
    return (jsonDecode(utf8.decode(res.bodyBytes)) as List).map((e) => _Post.fromJson(e)).toList();
  }

  static Future<void> upload(List<int> bytes, String caption) async {
    final res = await http
        .post(
          _u('/upload'),
          headers: {'Content-Type': 'image/jpeg', 'X-Caption': Uri.encodeComponent(caption)},
          body: bytes,
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 201) throw 'Upload fehlgeschlagen (${res.statusCode})';
  }

  /// true = Passwort korrekt
  static Future<bool> checkAdmin(String pw) async {
    final res = await http.get(_u('/admin/check'), headers: _auth(pw)).timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return true;
    if (res.statusCode == 401) return false;
    throw 'Serverfehler (${res.statusCode})';
  }

  static Future<({int openCount, List<_Post> posts})> adminPosts(String pw, {required bool open}) async {
    final res = await http
        .get(_u('/admin/posts', {'status': open ? 'pending' : 'done'}), headers: _auth(pw))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw 'Serverfehler (${res.statusCode})';
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (
      openCount: (j['openCount'] ?? 0) as int,
      posts: (j['posts'] as List).map((e) => _Post.fromJson(e)).toList(),
    );
  }

  static Future<void> moderate(String pw, String id, String action) async {
    final res = await http
        .post(_u('/admin/posts/$id'),
            headers: {..._auth(pw), 'Content-Type': 'application/json'}, body: jsonEncode({'action': action}))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw 'Serverfehler (${res.statusCode})';
  }
}

// ---------------------------------------------------------------------------
// 1) FEED  (Mockup Screen 4)
// ---------------------------------------------------------------------------

class CuratorialScreen extends StatefulWidget {
  const CuratorialScreen({super.key});

  @override
  State<CuratorialScreen> createState() => _CuratorialScreenState();
}

class _CuratorialScreenState extends State<CuratorialScreen> {
  bool _today = true;
  late Future<List<_Post>> _future;

  /// Admin-Passwort, nur im Arbeitsspeicher (wird nirgends gespeichert).
  String? _adminPassword;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_Post>> _load() {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    return _Api.feed(since: _today ? startOfToday : startOfToday.subtract(const Duration(days: 6)));
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _openCamera() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SubmitPhotoScreen()));
  }

  /// Langes Drücken auf den Titel -> Passwort -> Admin-Bereich.
  Future<void> _adminLogin() async {
    if (_adminPassword != null) {
      _openReview();
      return;
    }
    final controller = TextEditingController();
    final pw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        title: const Text('Admin', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'Passwort', hintStyle: TextStyle(color: _kMuted)),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('OK')),
        ],
      ),
    );
    if (pw == null || pw.isEmpty || !mounted) return;

    try {
      final ok = await _Api.checkAdmin(pw);
      if (!mounted) return;
      if (ok) {
        setState(() => _adminPassword = pw);
        _openReview();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Falsches Passwort.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fehler: $e')));
    }
  }

  void _openReview() {
    final pw = _adminPassword;
    if (pw == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReviewScreen(password: pw))).then((result) {
      // Passwort wurde vom Server abgelehnt (z. B. geändert) -> abmelden
      if (result == 'logout' && mounted) setState(() => _adminPassword = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      floatingActionButton: FloatingActionButton(
        backgroundColor: _kAccent,
        onPressed: _openCamera,
        child: const Icon(Icons.photo_camera_rounded, color: Colors.white),
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          GestureDetector(
            onLongPress: _adminLogin,
            child: const Text('Curatorial',
                style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: _Pill(
                      label: 'Heute',
                      selected: _today,
                      onTap: () {
                        _today = true;
                        _reload();
                      }),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Pill(
                      label: 'Diese Woche',
                      selected: !_today,
                      onTap: () {
                        _today = false;
                        _reload();
                      }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                _reload();
                await _future.catchError((_) => <_Post>[]);
              },
              child: FutureBuilder<List<_Post>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return _Scrollable(child: _Message('Fehler beim Laden:\n${snap.error}'));
                  }
                  final posts = snap.data ?? [];
                  if (posts.isEmpty) {
                    return _Scrollable(child: _Message(_today ? 'Heute noch keine Fotos.' : 'Diese Woche noch keine Fotos.'));
                  }
                  return ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                    itemCount: posts.length,
                    itemBuilder: (_, i) => _PostCard(post: posts[i]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  final _Post post;
  final Map<String, String>? headers;
  final Widget? footer;
  const _PostCard({required this.post, this.headers, this.footer});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: _kCard, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: CachedNetworkImage(
              imageUrl: post.imageUrl,
              httpHeaders: headers,
              width: double.infinity,
              fit: BoxFit.fitWidth,
              placeholder: (_, __) => const SizedBox(height: 220, child: Center(child: CircularProgressIndicator())),
              errorWidget: (_, __, ___) =>
                  const SizedBox(height: 120, child: Center(child: Icon(Icons.broken_image, color: _kMuted))),
            ),
          ),
          if (post.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(post.caption,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
            ),
          footer ??
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 6, 4, 2),
                child: Text('Anonym eingereicht', style: TextStyle(color: _kMuted, fontSize: 12)),
              ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2) EINREICHEN  (Mockup Screens 1 + 2)
// ---------------------------------------------------------------------------

class SubmitPhotoScreen extends StatefulWidget {
  const SubmitPhotoScreen({super.key});

  @override
  State<SubmitPhotoScreen> createState() => _SubmitPhotoScreenState();
}

class _SubmitPhotoScreenState extends State<SubmitPhotoScreen> {
  final _picker = ImagePicker();
  final _captionController = TextEditingController();
  File? _image;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _takePhoto());
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? shot = await _picker.pickImage(source: ImageSource.camera);
      if (shot == null) {
        if (mounted && _image == null) Navigator.of(context).pop();
        return;
      }
      final dir = await getTemporaryDirectory();
      File? result;
      // Qualität schrittweise senken, bis das Bild unter dem Limit liegt.
      for (final q in [85, 70, 55, 40]) {
        final out = await FlutterImageCompress.compressAndGetFile(
          shot.path,
          '${dir.path}/curatorial_${const Uuid().v4()}.jpg',
          quality: q,
          minWidth: 1600,
          minHeight: 1600,
          format: CompressFormat.jpeg,
        );
        if (out == null) break;
        result = File(out.path);
        if (await result.length() <= _kMaxBytes) break;
      }
      if (result == null || await result.length() > _kMaxBytes) {
        throw 'Foto konnte nicht verkleinert werden.';
      }
      if (!mounted) return;
      setState(() => _image = result);
    } catch (e) {
      if (!mounted) return;
      _snack('Kamera nicht verfügbar: $e');
      Navigator.of(context).pop();
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _submit() async {
    if (_image == null || _uploading) return;
    setState(() => _uploading = true);
    try {
      await _Api.upload(await _image!.readAsBytes(), _captionController.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Danke! Dein Foto wird geprüft.')));
    } catch (e) {
      if (mounted) _snack('Senden fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: _image == null
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _uploading ? null : () => Navigator.of(context).pop(),
                        child: const Text('Zurück', style: TextStyle(color: Colors.white70)),
                      ),
                    ),
                    ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(_image!, fit: BoxFit.fitWidth)),
                    TextButton.icon(
                      onPressed: _uploading
                          ? null
                          : () {
                              setState(() => _image = null);
                              _takePhoto();
                            },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Neues Foto'),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(color: _kCard, borderRadius: BorderRadius.circular(14)),
                      child: TextField(
                        controller: _captionController,
                        maxLength: _kMaxCaption,
                        maxLines: 3,
                        minLines: 2,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                        decoration: const InputDecoration(
                            border: InputBorder.none, hintText: 'Optional', hintStyle: TextStyle(color: _kMuted)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _uploading ? null : _submit,
                        child: _uploading
                            ? const SizedBox(
                                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Zur Prüfung senden', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Center(
                      child: Text('Ein Admin prüft dein Foto zuerst.', style: TextStyle(color: _kMuted, fontSize: 12)),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3) PRÜFUNG  (Mockup Screen 3)
// ---------------------------------------------------------------------------

class ReviewScreen extends StatefulWidget {
  final String password;
  const ReviewScreen({super.key, required this.password});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _open = true;
  late Future<({int openCount, List<_Post> posts})> _future;

  Map<String, String> get _headers => {'Authorization': 'Bearer ${widget.password}'};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<({int openCount, List<_Post> posts})> _load() async {
    try {
      return await _Api.adminPosts(widget.password, open: _open);
    } catch (e) {
      if (e.toString().contains('401') && mounted) Navigator.of(context).pop('logout');
      rethrow;
    }
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _moderate(_Post p, String action) async {
    try {
      await _Api.moderate(widget.password, p.id, action);
      _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fehler: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: const Text('Prüfung', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
      ),
      body: FutureBuilder<({int openCount, List<_Post> posts})>(
        future: _future,
        builder: (context, snap) {
          final data = snap.data;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _Pill(
                        label: data != null ? 'Offen ${data.openCount}' : 'Offen',
                        selected: _open,
                        onTap: () {
                          _open = true;
                          _reload();
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Pill(
                        label: 'Erledigt',
                        selected: !_open,
                        onTap: () {
                          _open = false;
                          _reload();
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: snap.connectionState != ConnectionState.done
                    ? const Center(child: CircularProgressIndicator())
                    : snap.hasError
                        ? _Message('Fehler beim Laden:\n${snap.error}')
                        : data!.posts.isEmpty
                            ? _Message(_open ? 'Nichts zu prüfen.' : 'Noch nichts erledigt.')
                            : RefreshIndicator(
                                onRefresh: () async {
                                  _reload();
                                  await _future.catchError((_) => (openCount: 0, posts: <_Post>[]));
                                },
                                child: ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                                  itemCount: data.posts.length,
                                  itemBuilder: (_, i) {
                                    final p = data.posts[i];
                                    final pending = p.status == 'pending';
                                    return _PostCard(
                                      post: p,
                                      // Offene Bilder sind nur mit Admin-Passwort abrufbar.
                                      headers: pending ? _headers : null,
                                      footer: Padding(
                                        padding: const EdgeInsets.only(top: 10),
                                        child: pending
                                            ? Row(
                                                children: [
                                                  Expanded(
                                                      child: _ActionButton(
                                                          label: 'Ablehnen',
                                                          color: _kCardLight,
                                                          onTap: () => _moderate(p, 'reject'))),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                      child: _ActionButton(
                                                          label: 'Freigeben',
                                                          color: _kAccent,
                                                          onTap: () => _moderate(p, 'approve'))),
                                                ],
                                              )
                                            : Text(
                                                p.status == 'approved' ? 'Freigegeben' : 'Abgelehnt',
                                                style: TextStyle(
                                                    color: p.status == 'approved' ? Colors.greenAccent : Colors.redAccent,
                                                    fontSize: 13),
                                              ),
                                      ),
                                    );
                                  },
                                ),
                              ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Kleine gemeinsame Widgets
// ---------------------------------------------------------------------------

class _Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Pill({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _kCardLight : _kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? _kAccent : Colors.transparent, width: 1.2),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: _kMuted))));
}

/// Damit Pull-to-Refresh auch bei leerer Liste funktioniert.
class _Scrollable extends StatelessWidget {
  final Widget child;
  const _Scrollable({required this.child});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(height: c.maxHeight, child: child),
        ),
      );
}
