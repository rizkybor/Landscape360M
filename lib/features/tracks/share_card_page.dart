import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../data/community/photo_compress.dart';
import '../../domain/community/community.dart' show PostKind, titleLimit;
import '../../domain/community/community_attachments.dart' show trackAttachment;
import '../../domain/tracks/share_card.dart';
import '../community/community_compose.dart' show openCompose;
import '../community/community_state.dart' show ComposeDraft;
import 'share_card.dart';
import 'track_recorder_state.dart';

// "Share as image" for a track (mobile app only): the four cards side by side, the numbers to
// show, "Hide start and end", a photo for the Photo card; then Share (Instagram story, WhatsApp
// status, Save Image… from the phone's share sheet), Copy sticker (iPhone: paste it on a photo in
// an Instagram story) or Post to Community (a Story with the card and the route attached).

/// A photo from the gallery for the Photo card; tests replace it
final cardPhotoPickerProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2160, maxHeight: 2160);
    return f?.readAsBytes();
  },
);

/// Saves the picture where the user picks (tests replace it)
final cardShareProvider = Provider<Future<void> Function(Uint8List png, String name)>(
  (ref) => (png, name) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(png, mimeType: 'image/png', name: name)],
        fileNameOverrides: [name],
      ),
    );
  },
);

/// [post]: straight on to Post to Community with the Map card (from "Track saved")
Future<void> openShareCard(BuildContext context, String trackId, {bool post = false}) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ShareCardPage(trackId: trackId, post: post),
      ),
    );

class ShareCardPage extends ConsumerStatefulWidget {
  const ShareCardPage({super.key, required this.trackId, this.post = false});

  final String trackId;
  final bool post;

  @override
  ConsumerState<ShareCardPage> createState() => _ShareCardPageState();
}

class _ShareCardPageState extends ConsumerState<ShareCardPage> {
  final _pages = PageController(viewportFraction: 0.74);
  final _capture = GlobalKey();
  TrackView? _track;
  ShareCardData? _data;
  MapShot? _shot;
  bool _shooting = false;
  Uint8List? _photo;
  ShareCardTemplate _template = ShareCardTemplate.map;
  ShareCardTemplate _rendering = ShareCardTemplate.map;
  Set<CardStat> _stats = CardStat.values.toSet();
  bool _hideEnds = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final v = await ref.read(trackRecorderProvider.notifier).load(widget.trackId);
    if (!mounted) return;
    if (v == null || v.points.length < 2) {
      setState(() => _error = 'This track has no route to share.');
      return;
    }
    _track = v;
    final data = ShareCardData.of(v.track, v.points);
    setState(() {
      _data = data;
      if (data.highestM == null) _stats = _stats.difference({CardStat.highest});
    });
    await _shoot();
    if (widget.post && mounted) await _post();
  }

  /// The map behind the Map card, again when the route is cut
  Future<void> _shoot() async {
    final d = _data;
    if (d == null) return;
    setState(() => _shooting = true);
    final shot = await ref.read(trackMapShotProvider)(d.line, shareCardSize);
    if (!mounted || _data != d) return;
    if (shot != null) await precacheImage(MemoryImage(shot.png), context);
    if (mounted) {
      setState(() {
        _shot = shot;
        _shooting = false;
      });
    }
  }

  void _setHideEnds(bool v) {
    final t = _track;
    if (t == null) return;
    setState(() {
      _hideEnds = v;
      _data = ShareCardData.of(t.track, t.points, hideEnds: v);
      _shot = null;
    });
    unawaited(_shoot());
  }

  Future<void> _pickPhoto() async {
    final bytes = await ref.read(cardPhotoPickerProvider)();
    if (bytes == null || !mounted) return;
    await precacheImage(MemoryImage(bytes), context);
    setState(() => _photo = bytes);
  }

  /// The card of [template] at 1080 × 1920, drawn off screen
  Future<Uint8List> _render(ShareCardTemplate template) async {
    setState(() => _rendering = template);
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    final boundary = _capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: shareCardPixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes!.buffer.asUint8List();
  }

  String get _fileName {
    final base = (_data?.name ?? 'track').replaceAll(RegExp(r'[^\w\- ]+'), '').trim().replaceAll(RegExp(r'\s+'), '_');
    return '${base.isEmpty ? 'track' : base}_${_template.name}.png';
  }

  Future<void> _act(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Could not make the picture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() => _act(() async {
    final png = await _render(_template);
    await ref.read(cardShareProvider)(png, _fileName);
  });

  Future<void> _copySticker() => _act(() async {
    await Pasteboard.writeImage(await _render(ShareCardTemplate.sticker));
    unawaited(HapticFeedback.lightImpact());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sticker copied. In your Instagram story, tap the text tool and Paste.')),
      );
    }
  });

  /// A Story with the card as its photo (the Map card for the transparent sticker) and the route
  Future<void> _post() => _act(() async {
    final d = _data!;
    final png = await _render(_template == ShareCardTemplate.sticker ? ShareCardTemplate.map : _template);
    final photo = await compressPhotoInBackground(png);
    final top = d.top;
    final draft = ComposeDraft(
      kind: PostKind.story,
      title: d.name.length > titleLimit ? d.name.substring(0, titleLimit) : d.name,
      happenedOn: postDate(d.date),
      lat: top?.$2,
      lng: top?.$1,
      photos: [photo],
      attachment: trackAttachment(name: d.name, distanceM: d.distanceM, points: d.line),
    );
    if (!mounted) return;
    final posted = await openCompose(context, draft: draft);
    if (posted == true && mounted) Navigator.of(context).pop();
  });

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: L360Colors.ink,
      appBar: AppBar(
        backgroundColor: L360Colors.ink,
        foregroundColor: Colors.white,
        title: const Text('Share as image'),
      ),
      body: d == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!, style: const TextStyle(color: Colors.white)),
            )
          : Stack(
              children: [
                // The picture being saved, drawn at its real size out of sight
                Positioned(
                  left: -shareCardSize.width * 3,
                  top: 0,
                  child: RepaintBoundary(
                    key: _capture,
                    child: ShareCard(template: _rendering, data: d, stats: _stats, mapShot: _shot, photo: _photo),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      Expanded(
                        child: PageView.builder(
                          key: const Key('share-cards'),
                          controller: _pages,
                          itemCount: ShareCardTemplate.values.length,
                          onPageChanged: (i) => setState(() => _template = ShareCardTemplate.values[i]),
                          itemBuilder: (context, i) => _Preview(
                            template: ShareCardTemplate.values[i],
                            card: ShareCard(
                              template: ShareCardTemplate.values[i],
                              data: d,
                              stats: _stats,
                              mapShot: _shot,
                              photo: _photo,
                            ),
                            loadingMap: _shooting && ShareCardTemplate.values[i] == ShareCardTemplate.map,
                            onTap: ShareCardTemplate.values[i] == ShareCardTemplate.photo ? _pickPhoto : null,
                          ),
                        ),
                      ),
                      _Controls(
                        template: _template,
                        onTemplate: (t) => _pages.animateToPage(
                          t.index,
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                        ),
                        stats: _stats,
                        canHighest: d.highestM != null,
                        onStat: (s, on) => setState(() => _stats = on ? {..._stats, s} : _stats.difference({s})),
                        hideEnds: _hideEnds,
                        onHideEnds: _setHideEnds,
                        hasPhoto: _photo != null,
                        onPhoto: _pickPhoto,
                        busy: _busy,
                        error: _error,
                        onShare: _share,
                        onCopySticker: _template == ShareCardTemplate.sticker && Platform.isIOS ? _copySticker : null,
                        onPost: _post,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// A card scaled to fit, over a chequerboard for the transparent sticker
class _Preview extends StatelessWidget {
  const _Preview({required this.template, required this.card, required this.loadingMap, this.onTap});

  final ShareCardTemplate template;
  final Widget card;
  final bool loadingMap;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
    child: Center(
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: GestureDetector(
          key: Key('share-card-${template.name}'),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (template == ShareCardTemplate.sticker) const CustomPaint(painter: _Checker()),
                FittedBox(child: card),
                if (loadingMap)
                  const Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Checker extends CustomPainter {
  const _Checker();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF6B6B6B));
    final p = Paint()..color = const Color(0xFF5A5A5A);
    const s = 14.0;
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = ((y / s).floor().isEven ? 0.0 : s); x < size.width; x += s * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), p);
      }
    }
  }

  @override
  bool shouldRepaint(_Checker old) => false;
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.template,
    required this.onTemplate,
    required this.stats,
    required this.canHighest,
    required this.onStat,
    required this.hideEnds,
    required this.onHideEnds,
    required this.hasPhoto,
    required this.onPhoto,
    required this.busy,
    required this.error,
    required this.onShare,
    required this.onCopySticker,
    required this.onPost,
  });

  final ShareCardTemplate template;
  final void Function(ShareCardTemplate) onTemplate;
  final Set<CardStat> stats;
  final bool canHighest;
  final void Function(CardStat, bool) onStat;
  final bool hideEnds;
  final void Function(bool) onHideEnds;
  final bool hasPhoto;
  final VoidCallback onPhoto;
  final bool busy;
  final String? error;
  final VoidCallback onShare;
  final VoidCallback? onCopySticker;
  final VoidCallback onPost;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, bool on, VoidCallback onTap, {Key? key}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        key: key,
        label: Text(label),
        selected: on,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        labelStyle: TextStyle(color: on ? L360Colors.ink : Colors.white, fontWeight: FontWeight.w600),
        selectedColor: Colors.white,
        backgroundColor: const Color(0xFF2B3326),
        side: const BorderSide(color: Color(0xFF3D4636)),
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final t in ShareCardTemplate.values)
                  chip(t.label, t == template, () => onTemplate(t), key: Key('share-template-${t.name}')),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final s in CardStat.values)
                  if (s != CardStat.highest || canHighest)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        key: Key('share-stat-${s.name}'),
                        label: Text(s.label),
                        selected: stats.contains(s),
                        onSelected: (on) => onStat(s, on),
                        checkmarkColor: L360Colors.ink,
                        labelStyle: TextStyle(color: stats.contains(s) ? L360Colors.ink : Colors.white),
                        selectedColor: L360Colors.gold500,
                        backgroundColor: const Color(0xFF2B3326),
                        side: const BorderSide(color: Color(0xFF3D4636)),
                      ),
                    ),
              ],
            ),
          ),
          SwitchListTile.adaptive(
            key: const Key('share-hide-ends'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Hide start and end', style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: const Text(
              'Leaves out the first and last 200 m (your home or basecamp)',
              style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
            ),
            value: hideEnds,
            onChanged: onHideEnds,
          ),
          if (template == ShareCardTemplate.photo)
            TextButton.icon(
              key: const Key('share-photo'),
              style: TextButton.styleFrom(foregroundColor: L360Colors.gold500),
              onPressed: onPhoto,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: Text(hasPhoto ? 'Change photo' : 'Choose a photo'),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(error!, style: const TextStyle(color: Color(0xFFFFB4A8), fontSize: 12)),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('share-send'),
                  style: FilledButton.styleFrom(
                    backgroundColor: L360Colors.ember500,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 48),
                  ),
                  onPressed: busy ? null : onShare,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.ios_share, size: 20),
                  label: const Text('Share'),
                ),
              ),
              if (onCopySticker != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('share-copy-sticker'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0x66FFFFFF)),
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: busy ? null : onCopySticker,
                    icon: const Icon(Icons.content_copy, size: 18),
                    label: const Text('Copy sticker'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('share-post'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0x66FFFFFF)),
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: busy ? null : onPost,
            icon: const Icon(Icons.forum_outlined, size: 18),
            label: const Text('Post to Community'),
          ),
        ],
      ),
    );
  }
}
