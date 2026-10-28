import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/sos/sos.dart';
import '../../domain/survey/survey_utils.dart';
import '../../domain/util/js_compat.dart';
import 'sos_state.dart';

// Full-screen S.O.S (SosScreen.tsx): countdown, then the position large enough to read out
// over a radio, the report to the admin, calls, SMS, share, siren and the S.O.S light.

/// Opens the S.O.S screen over everything
Future<void> openSosScreen(BuildContext context, WidgetRef ref) async {
  unawaited(ref.read(sosProvider.notifier).open());
  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      fullscreenDialog: true,
      pageBuilder: (_, _, _) => const SosScreen(),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ),
  );
}

const _red = Color(0xFF962620); // brick-600/700 of the web

class SosScreen extends ConsumerStatefulWidget {
  const SosScreen({super.key});

  @override
  ConsumerState<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends ConsumerState<SosScreen> {
  final _message = TextEditingController();
  Timer? _clock;
  Timer? _flash;
  bool _flashOn = false;
  bool _showContacts = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _flash?.cancel();
    _message.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    _stopLight();
    await ref.read(sosProvider.notifier).close();
    if (mounted) Navigator.of(context).pop();
  }

  // Morse ··· ——— ··· with the LED torch and a white screen
  void _toggleLight() {
    final sos = ref.read(sosProvider.notifier);
    if (ref.read(sosProvider).light) {
      _stopLight();
      return;
    }
    sos.setLight(true);
    final device = ref.read(sosDeviceProvider);
    var i = 0;
    void step() {
      final (on, off) = sosLightPattern[i % sosLightPattern.length];
      setState(() => _flashOn = true);
      unawaited(device.torch(true));
      _flash = Timer(Duration(milliseconds: on), () {
        if (!mounted) return;
        setState(() => _flashOn = false);
        unawaited(device.torch(false));
        _flash = Timer(Duration(milliseconds: off), () {
          i++;
          if (mounted && ref.read(sosProvider).light) step();
        });
      });
    }

    step();
  }

  void _stopLight() {
    _flash?.cancel();
    _flash = null;
    if (mounted) setState(() => _flashOn = false);
    unawaited(ref.read(sosDeviceProvider).torch(false));
    ref.read(sosProvider.notifier).setLight(false);
  }

  void _flashNote(String text) {
    setState(() => _note = text);
    Future<void>.delayed(const Duration(milliseconds: 3500), () {
      if (mounted && _note == text) setState(() => _note = null);
    });
  }

  String get _userName {
    final p = ref.read(profileProvider).value;
    if (p == null) return '';
    return p.displayName.isNotEmpty ? p.displayName : p.email;
  }

  Future<void> _open(String url) async {
    if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      _flashNote('This phone cannot open $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sosProvider);
    return PopScope(
      canPop: false, // only Cancel / I'm safe close it
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: _red,
          body: Stack(
            children: [
              DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white),
                child: IconTheme.merge(
                  data: const IconThemeData(color: Colors.white),
                  child: s.phase == SosPhase.active ? _active(s) : _countdown(s),
                ),
              ),
              if (_flashOn)
                const Positioned.fill(
                  child: IgnorePointer(child: ColoredBox(color: Colors.white)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _countdown(SosState s) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('STARTING S.O.S', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 3.5)),
          const SizedBox(height: 16),
          Text(
            '${s.countdown}',
            key: const Key('sos-countdown'),
            style: const TextStyle(fontSize: 112, fontWeight: FontWeight.w900, height: 1),
          ),
          const SizedBox(height: 16),
          const Text(
            'Opening the emergency screen. Cancel if this was a mistake.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15),
          ),
          const SizedBox(height: 28),
          _BigButton(key: const Key('sos-cancel'), label: 'Cancel', onPressed: _close),
        ],
      ),
    ),
  );

  Widget _active(SosState s) {
    final fix = s.fix;
    final contacts = ref.watch(emergencyContactsProvider).value ?? const <EmergencyContact>[];
    final message = buildSosMessage(_userName, fix);
    final elapsed = s.startedAt == null ? 0 : DateTime.now().millisecondsSinceEpoch - s.startedAt!;
    final secs = elapsed ~/ 1000;
    String p(int n) => n.toString().padLeft(2, '0');
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
            child: Row(
              children: [
                const _Pulse(),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('S.O.S ACTIVE', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2.5)),
                ),
                Text(
                  '${p(secs ~/ 3600)}:${p(secs % 3600 ~/ 60)}:${p(secs % 60)}',
                  style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              children: [
                _Box(
                  dark: 0.2,
                  child: fix == null
                      ? Text(s.gpsError ?? 'Searching for GPS…', style: const TextStyle(fontWeight: FontWeight.w700))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${toDMS(fix.lat, isLat: true)}\n${toDMS(fix.lng, isLat: false)}',
                              key: const Key('sos-dms'),
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.3),
                            ),
                            const SizedBox(height: 4),
                            Text('${fix.lat.toStringAsFixed(5)}, ${fix.lng.toStringAsFixed(5)}'),
                            Text('UTM ${toUTM(fix.lat, fix.lng)}'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                if (fix.elevation != null) Text('Elev ${jsRoundStr(fix.elevation!)} m'),
                                if (fix.accuracy != null) Text('±${jsRoundStr(fix.accuracy!)} m'),
                                Text(_ago(fix.time)),
                                if (s.battery != null)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [const Icon(Icons.battery_std, size: 14), Text(' ${s.battery}%')],
                                  ),
                              ],
                            ),
                          ],
                        ),
                ),
                const SizedBox(height: 14),
                _Box(
                  dark: 0.15,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Text('Admin', style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(width: 8),
                          Expanded(child: _DeliveryLine(state: s)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('sos-message'),
                              controller: _message,
                              maxLength: 500,
                              style: const TextStyle(color: L360Colors.ink),
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              decoration: const InputDecoration(
                                counterText: '',
                                isDense: true,
                                filled: true,
                                fillColor: Colors.white,
                                hintText: 'Message, e.g. sprained ankle at post 3, 2 people',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            key: const Key('sos-send'),
                            style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: _red),
                            tooltip: 'Send the message to the admin',
                            onPressed: _send,
                            icon: const Icon(Icons.send),
                          ),
                        ],
                      ),
                      if (s.sentMessage.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Message sent: “${s.sentMessage}”', style: const TextStyle(fontSize: 12)),
                        ),
                      const SizedBox(height: 6),
                      const Text(
                        'Your location, battery and time go to the admin every 30 s while S.O.S is on, also '
                        'with the screen off. Without signal they wait on this phone and go out when it is back.',
                        style: TextStyle(fontSize: 12, color: Color(0xDDFFFFFF)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 2.6,
                  children: [
                    for (final n in emergencyNumbers)
                      _Action(
                        key: Key('sos-call-${n.number}'),
                        icon: Icons.phone,
                        label: n.label,
                        solid: true,
                        onTap: () => _open('tel:${n.number}'),
                      ),
                    _Action(
                      key: const Key('sos-sms'),
                      icon: Icons.sms_outlined,
                      label: contacts.isEmpty ? 'Add SMS contacts' : 'SMS (${contacts.length})',
                      onTap: () => contacts.isEmpty
                          ? setState(() => _showContacts = true)
                          : _open(smsUrl([for (final c in contacts) c.phone], message, ios: Platform.isIOS)),
                    ),
                    _Action(
                      key: const Key('sos-share'),
                      icon: Icons.ios_share,
                      label: 'Share location',
                      onTap: () => SharePlus.instance.share(ShareParams(text: message, title: 'S.O.S')),
                    ),
                    _Action(
                      key: const Key('sos-siren'),
                      icon: Icons.volume_up,
                      label: s.siren ? 'Stop siren' : 'Siren',
                      solid: s.siren,
                      onTap: () => ref.read(sosProvider.notifier).toggleSiren(),
                    ),
                    _Action(
                      key: const Key('sos-light'),
                      icon: Icons.flashlight_on_outlined,
                      label: s.light ? 'Stop light' : 'S.O.S light',
                      solid: s.light,
                      onTap: _toggleLight,
                    ),
                  ],
                ),
                if (_note != null) ...[
                  const SizedBox(height: 10),
                  _Box(
                    dark: 0.25,
                    child: Text(_note!, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
                const SizedBox(height: 14),
                _Contacts(
                  contacts: contacts,
                  open: _showContacts,
                  onToggle: () => setState(() => _showContacts = !_showContacts),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Calls and SMS open in your phone apps: press Call / Send there. SMS needs mobile signal but no '
                  'internet. Without any signal, read your coordinates over a radio, use the siren and light, and '
                  'stay where you are if it is safe. This does not replace a satellite messenger or PLB.',
                  style: TextStyle(fontSize: 12, height: 1.45, color: Color(0xCCFFFFFF)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
            child: _BigButton(key: const Key('sos-safe'), label: "I'm safe", icon: Icons.close, onPressed: _close),
          ),
        ],
      ),
    );
  }

  void _send() {
    final text = _message.text.trim();
    if (text.isEmpty) return;
    _message.clear();
    FocusScope.of(context).unfocus();
    unawaited(ref.read(sosProvider.notifier).sendMessage(text));
  }

  static String _ago(int ms) {
    final s = ((DateTime.now().millisecondsSinceEpoch - ms) / 1000).round().clamp(0, 1 << 31);
    return s < 60 ? '$s s ago' : '${(s / 60).round()} min ago';
  }
}

class _DeliveryLine extends StatelessWidget {
  const _DeliveryLine({required this.state});
  final SosState state;

  @override
  Widget build(BuildContext context) {
    String hm(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }

    final (icon, text) = switch (state.delivery) {
      SosDelivery.sent => (Icons.check, 'Sent to the admin ${hm(state.sentAt!)}'),
      SosDelivery.waiting => (Icons.cloud_off, 'Waiting for signal, sends automatically'),
      SosDelivery.error => (Icons.error_outline, 'Not sent: ${state.deliveryError ?? ''}'),
      _ => (Icons.sync, 'Sending to the admin…'),
    };
    return Row(
      key: const Key('sos-delivery'),
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _Contacts extends ConsumerStatefulWidget {
  const _Contacts({required this.contacts, required this.open, required this.onToggle});

  final List<EmergencyContact> contacts;
  final bool open;
  final VoidCallback onToggle;

  @override
  ConsumerState<_Contacts> createState() => _ContactsState();
}

class _ContactsState extends ConsumerState<_Contacts> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final problem = await ref.read(emergencyContactsProvider.notifier).add(_name.text, _phone.text);
    setState(() => _error = problem);
    if (problem == null) {
      _name.clear();
      _phone.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = widget.contacts;
    const field = InputDecoration(isDense: true, filled: true, fillColor: Colors.white, counterText: '');
    return _Box(
      dark: 0.15,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: widget.onToggle,
            child: Row(
              children: [
                const Icon(Icons.people_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Emergency contacts (${contacts.length}/$maxEmergencyContacts)',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(widget.open ? 'Hide' : 'Edit', style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          if (widget.open) ...[
            const SizedBox(height: 10),
            for (final (i, c) in contacts.indexed)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.only(left: 12),
                decoration: BoxDecoration(color: const Color(0x1AFFFFFF), borderRadius: BorderRadius.circular(10)),
                child: Row(
                  children: [
                    Expanded(child: Text('${c.name} · ${c.phone}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    IconButton(
                      tooltip: 'Remove ${c.name}',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => ref.read(emergencyContactsProvider.notifier).remove(i),
                    ),
                  ],
                ),
              ),
            if (contacts.length < maxEmergencyContacts)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('sos-contact-name'),
                      controller: _name,
                      maxLength: 40,
                      style: const TextStyle(color: L360Colors.ink),
                      decoration: field.copyWith(hintText: 'Name'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('sos-contact-phone'),
                      controller: _phone,
                      maxLength: 20,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(color: L360Colors.ink),
                      decoration: field.copyWith(hintText: 'Phone'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const Key('sos-contact-add'),
                    style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: _red),
                    tooltip: 'Add contact',
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            const SizedBox(height: 6),
            const Text(
              'Saved on this phone, so they work without signal.',
              style: TextStyle(fontSize: 12, color: Color(0xCCFFFFFF)),
            ),
          ],
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.dark, required this.child});
  final double dark;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: dark),
      borderRadius: BorderRadius.circular(18),
    ),
    child: child,
  );
}

class _Action extends StatelessWidget {
  const _Action({super.key, required this.icon, required this.label, required this.onTap, this.solid = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool solid;

  @override
  Widget build(BuildContext context) => Material(
    color: solid ? Colors.white : const Color(0x26FFFFFF),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: solid ? BorderSide.none : const BorderSide(color: Color(0x4DFFFFFF)),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: solid ? _red : Colors.white),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: solid ? _red : Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

class _BigButton extends StatelessWidget {
  const _BigButton({super.key, required this.label, required this.onPressed, this.icon});

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 58,
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: _red,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      onPressed: onPressed,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon),
      label: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
    ),
  );
}

class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 0.3, end: 1).animate(_c),
    child: Container(
      width: 12,
      height: 12,
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
    ),
  );
}
