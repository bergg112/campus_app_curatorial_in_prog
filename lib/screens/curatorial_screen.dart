import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// Shared constants / helpers
// ---------------------------------------------------------------------------

const _kCollection = 'curatorial_posts';
const _kAccent = Color(0xFF3B82F6);
const _kBg = Color(0xFF0E1420);
const _kCard = Color(0xFF151D2E);
const _kCardLight = Color(0xFF1C2638);
const _kMuted = Color(0xFF8A93A6);
const _kMaxCaption = 100;

/// Simple client-side admin gate. NOTE: this only hides the UI. Real protection
/// has to come from Firestore / Storage security rules (or Firebase Auth).
const _kAdminPin = '1234'; // TODO: change / replace by real auth

enum _Status { pending, approved, rejected }

_Status _statusOf(Map<String, dynamic> d) {
  switch (d['status']) {
    case 'approved':
      return _Status.approved;
    case 'rejected':
      return _Status.rejected;
    default:
      return _Status.pending;
  }
}

DateTime _timeOf(Map<String, dynamic> d) {
  final t = d['timestamp'];
  if (t is int) return DateTime.fromMillisecondsSinceEpoch(t);
  if (t is Timestamp) return t.toDate();
  return DateTime.fromMillisecondsSinceEpoch(0);
}

CollectionReference<Map<String, dynamic>> get _posts => FirebaseFirestore.instance.collection(_kCollection);

// ---------------------------------------------------------------------------
// 1) FEED  (mockup screen 4: "Curatorial" with Heute / Diese Woche)
// ---------------------------------------------------------------------------

class CuratorialScreen extends StatefulWidget {
  const CuratorialScreen({super.key});

  @override
  State<CuratorialScreen> createState() => _CuratorialScreenState();
}

class _CuratorialScreenState extends State<CuratorialScreen> {
  bool _today = true;
  bool _isAdmin = false;

  Future<void> _openCamera() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SubmitPhotoScreen()));
  }

  /// Long-press on the title unlocks the review screen (see _kAdminPin).
  Future<void> _adminLogin() async {
    if (_isAdmin) {
      _openReview();
      return;
    }
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        title: const Text('Admin', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'PIN', hintStyle: TextStyle(color: _kMuted)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text == _kAdminPin), child: const Text('OK')),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => _isAdmin = true);
      _openReview();
    }
  }

  void _openReview() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReviewScreen()));
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
            child: const Text(
              'Curatorial',
              style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: _Pill(label: 'Heute', selected: _today, onTap: () => setState(() => _today = true))),
                const SizedBox(width: 12),
                Expanded(
                  child: _Pill(label: 'Diese Woche', selected: !_today, onTap: () => setState(() => _today = false)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              // Single-field query -> no composite index needed. Sorting is done client-side.
              stream: _posts.where('status', isEqualTo: 'approved').limit(200).snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return _Message('Fehler beim Laden:\n${snap.error}');
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final now = DateTime.now();
                final start = _today
                    ? DateTime(now.year, now.month, now.day)
                    : DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
                final docs = snap.data!.docs.map((d) => d.data()).where((d) => !_timeOf(d).isBefore(start)).toList()
                  ..sort((a, b) => _timeOf(b).compareTo(_timeOf(a)));

                if (docs.isEmpty) {
                  return _Message(_today ? 'Heute noch keine Fotos.' : 'Diese Woche noch keine Fotos.');
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                  itemCount: docs.length,
                  itemBuilder: (_, i) => _PostCard(data: docs[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _PostCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final url = (data['imageUrl'] ?? '').toString();
    final caption = (data['caption'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: _kCard, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (url.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CachedNetworkImage(
                imageUrl: url,
                width: double.infinity,
                fit: BoxFit.fitWidth,
                placeholder: (_, __) => const SizedBox(height: 220, child: Center(child: CircularProgressIndicator())),
                errorWidget: (_, __, ___) => const SizedBox(height: 120, child: Icon(Icons.broken_image, color: _kMuted)),
              ),
            ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(caption, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
            ),
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
// 2) SUBMIT  (mockup screens 1 + 2: camera -> caption -> "Zur Prüfung senden")
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
  bool _cameraOpened = false;

  @override
  void initState() {
    super.initState();
    // Open the camera right away (step 1 of the mockup).
    WidgetsBinding.instance.addPostFrameCallback((_) => _takePhoto());
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    if (_cameraOpened && _image != null) return;
    _cameraOpened = true;
    try {
      final XFile? shot = await _picker.pickImage(source: ImageSource.camera, imageQuality: 100);
      if (shot == null) {
        if (mounted && _image == null) Navigator.of(context).pop();
        return;
      }
      final dir = await getTemporaryDirectory();
      final target = '${dir.path}/curatorial_${const Uuid().v4()}.jpg';
      final compressed = await FlutterImageCompress.compressAndGetFile(
        shot.path,
        target,
        quality: 85,
        minWidth: 1600,
        minHeight: 1600,
      );
      if (!mounted) return;
      setState(() => _image = File(compressed?.path ?? shot.path));
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
      final ref = FirebaseStorage.instance.ref().child('curatorial/${const Uuid().v4()}.jpg');
      await ref.putFile(_image!, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();

      await _posts.add({
        'imageUrl': url,
        'caption': _captionController.text.trim(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'pending',
      });

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
                              _cameraOpened = false;
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
                          border: InputBorder.none,
                          hintText: 'Optional',
                          hintStyle: TextStyle(color: _kMuted),
                        ),
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
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
// 3) REVIEW  (mockup screen 3: "Prüfung" with Offen / Erledigt)
// ---------------------------------------------------------------------------

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _open = true;

  Future<void> _setStatus(String id, String status) async {
    try {
      await _posts.doc(id).update({'status': status});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fehler: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(backgroundColor: _kBg, foregroundColor: Colors.white, elevation: 0, centerTitle: true, title: const Text('Prüfung', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700))),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _posts.limit(300).snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return _Message('Fehler beim Laden:\n${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());

          final all = snap.data!.docs.toList()
            ..sort((a, b) => _timeOf(b.data()).compareTo(_timeOf(a.data())));
          final openDocs = all.where((d) => _statusOf(d.data()) == _Status.pending).toList();
          final doneDocs = all.where((d) => _statusOf(d.data()) != _Status.pending).toList();
          final shown = _open ? openDocs : doneDocs;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Expanded(child: _Pill(label: 'Offen ${openDocs.length}', selected: _open, onTap: () => setState(() => _open = true))),
                    const SizedBox(width: 12),
                    Expanded(child: _Pill(label: 'Erledigt', selected: !_open, onTap: () => setState(() => _open = false))),
                  ],
                ),
              ),
              Expanded(
                child: shown.isEmpty
                    ? _Message(_open ? 'Nichts zu prüfen.' : 'Noch nichts erledigt.')
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final doc = shown[i];
                          final d = doc.data();
                          final st = _statusOf(d);
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: _kCard, borderRadius: BorderRadius.circular(18)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if ((d['imageUrl'] ?? '').toString().isNotEmpty)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: CachedNetworkImage(imageUrl: d['imageUrl'], width: double.infinity, fit: BoxFit.fitWidth),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (st == _Status.pending)
                                        const Padding(
                                          padding: EdgeInsets.only(top: 6, right: 8),
                                          child: Icon(Icons.circle, size: 8, color: Colors.redAccent),
                                        ),
                                      Expanded(
                                        child: Text((d['caption'] ?? '').toString().isEmpty ? '(ohne Text)' : d['caption'],
                                            style: const TextStyle(color: Colors.white, fontSize: 16)),
                                      ),
                                    ],
                                  ),
                                ),
                                if (st == _Status.pending)
                                  Row(
                                    children: [
                                      Expanded(child: _ActionButton(label: 'Ablehnen', color: _kCardLight, onTap: () => _setStatus(doc.id, 'rejected'))),
                                      const SizedBox(width: 10),
                                      Expanded(child: _ActionButton(label: 'Freigeben', color: _kAccent, onTap: () => _setStatus(doc.id, 'approved'))),
                                    ],
                                  )
                                else
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Text(st == _Status.approved ? 'Freigegeben' : 'Abgelehnt',
                                        style: TextStyle(color: st == _Status.approved ? Colors.greenAccent : Colors.redAccent, fontSize: 13)),
                                  ),
                              ],
                            ),
                          );
                        },
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
// Small shared widgets
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
  Widget build(BuildContext context) =>
      Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: _kMuted))));
}
