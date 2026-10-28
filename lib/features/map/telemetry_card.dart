import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../domain/map/map_settings.dart';
import '../../domain/survey/survey_utils.dart';

/// What the telemetry card shows: the map center and the camera
class Telemetry {
  const Telemetry({
    required this.lng,
    required this.lat,
    required this.pitch,
    required this.bearing,
    this.elevation,
    this.slope,
  });

  final double lng;
  final double lat;
  final double? elevation; // meters, null until the terrain answers
  final double? slope; // degrees
  final double pitch;
  final double bearing;

  Telemetry withCamera({required double lng, required double lat, required double pitch, required double bearing}) =>
      Telemetry(lng: lng, lat: lat, pitch: pitch, bearing: bearing, elevation: elevation, slope: slope);
}

const _mono = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

/// Position card (same readings as the web's): the point under the crosshair. Collapsed it
/// shows the coordinates and elevation; tapped it opens slope, pitch, bearing and DD / DMS.
class TelemetryCard extends StatelessWidget {
  const TelemetryCard({
    super.key,
    required this.telemetry,
    required this.format,
    required this.onFormatChanged,
    this.expanded = true,
    this.onToggle,
  });

  final Telemetry telemetry;
  final CoordFormat format;
  final ValueChanged<CoordFormat> onFormatChanged;
  final bool expanded;
  final VoidCallback? onToggle;

  String _lat() => format == CoordFormat.dms ? toDMS(telemetry.lat, isLat: true) : telemetry.lat.toStringAsFixed(5);
  String _lng() => format == CoordFormat.dms ? toDMS(telemetry.lng, isLat: false) : telemetry.lng.toStringAsFixed(5);
  String _elev() => telemetry.elevation == null ? '—' : '${telemetry.elevation!.toStringAsFixed(1)} mdpl';

  @override
  Widget build(BuildContext context) {
    final t = telemetry;
    return GestureDetector(
      key: const Key('telemetry-card'),
      behavior: HitTestBehavior.opaque,
      onTap: onToggle == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onToggle!();
            },
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: expanded ? 210 : null,
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 12, color: L360Colors.ink, fontFamily: 'Inter'),
              child: expanded ? _expanded(t) : _collapsed(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _collapsed() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.my_location, size: 15, color: L360Colors.forest700),
      const SizedBox(width: 8),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${_lat()}, ${_lng()}', style: _mono.copyWith(fontWeight: FontWeight.w600, fontSize: 12)),
          Text(
            _elev(),
            style: _mono.copyWith(color: L360Colors.gold700, fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
      const SizedBox(width: 6),
      const Icon(Icons.expand_more, size: 18, color: L360Colors.sand500),
    ],
  );

  Widget _expanded(Telemetry t) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Text(
            'POSITION',
            style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: L360Colors.sand500),
          ),
          const Spacer(),
          _FormatToggle(format: format, onChanged: onFormatChanged),
        ],
      ),
      const SizedBox(height: 8),
      _row('Lat', _lat()),
      _row('Lng', _lng()),
      _row('Elev', _elev(), color: L360Colors.gold700),
      _row('Slope', t.slope == null ? '—' : '${t.slope!.toStringAsFixed(1)}°'),
      const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider()),
      _row('Pitch', '${t.pitch.toStringAsFixed(1)}°', muted: true),
      _row('Bearing', '${normalizeBearing(t.bearing).toStringAsFixed(1)}°', muted: true),
    ],
  );

  Widget _row(String label, String value, {Color? color, bool muted = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label, style: const TextStyle(color: L360Colors.sand600)),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: _mono.copyWith(
              fontWeight: muted ? FontWeight.w500 : FontWeight.w700,
              color: color ?? (muted ? L360Colors.sand700 : L360Colors.ink),
            ),
          ),
        ),
      ],
    ),
  );
}

class _FormatToggle extends StatelessWidget {
  const _FormatToggle({required this.format, required this.onChanged});

  final CoordFormat format;
  final ValueChanged<CoordFormat> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(8)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final f in CoordFormat.values)
          GestureDetector(
            key: Key('coord-${f.name}'),
            onTap: () {
              HapticFeedback.selectionClick();
              onChanged(f);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: format == f ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                boxShadow: format == f ? const [BoxShadow(color: Color(0x14000000), blurRadius: 3)] : null,
              ),
              child: Text(
                f.name.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: format == f ? L360Colors.forest800 : L360Colors.sand500,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
