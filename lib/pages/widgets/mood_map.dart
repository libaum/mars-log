import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// A month's route, one line per day, coloured by that day's mood.
///
/// The base map is a real, cartographer-drawn street map in its own colours,
/// identical in light and dark mode: recolouring it by matrix only ever
/// produced muddy hues, and a bright map on a black screen turned out to be
/// fine — the map is a window, not a surface of the app.
/// Days without an entry have no mood to show, so their line is drawn dashed
/// in the neutral gray — a second, non-colour channel, so "no entry" can't be
/// misread as "middling mood".
class MoodMap extends StatefulWidget {
  /// Points of each day of the displayed month, keyed by day-of-month.
  final Map<int, List<DayLocationPoint>> pointsByDay;

  /// Mood score (0-10) per day-of-month — [MonthStats.moodByDay].
  final Map<int, double> moodByDay;

  /// Forces a fresh camera fit when the displayed month changes.
  final String monthKey;

  /// Called with the day-of-month of the line that was tapped.
  final void Function(int day)? onDayTap;

  /// Called when the tap didn't land on any line — used inline to open the
  /// fullscreen map, since a tap on a route already means "open that day".
  final VoidCallback? onTapEmpty;

  /// Fullscreen mode: fills the space it's given and allows panning. Inline
  /// the map is a fixed-height, non-pannable preview, because it lives in a
  /// scrolling list wrapped in a horizontal month-swipe detector.
  final bool expanded;

  const MoodMap({
    super.key,
    required this.pointsByDay,
    required this.moodByDay,
    required this.monthKey,
    this.onDayTap,
    this.onTapEmpty,
    this.expanded = false,
  });

  @override
  State<MoodMap> createState() => _MoodMapState();
}

class _MoodMapState extends State<MoodMap> {
  /// Filled by the polyline layer's own hit test on every pointer event; the
  /// tap handler below just reads whatever it last saw.
  ///
  /// Must be `<Object>`, not `<int>`: the layer always constructs a
  /// `LayerHitResult<Object>` (its internal hit list is `List<Object>`), so a
  /// narrower notifier throws a TypeError on the first tap. The day is cast
  /// back out in [_handleTap].
  final LayerHitNotifier<Object> _hitNotifier = ValueNotifier(null);

  @override
  void dispose() {
    _hitNotifier.dispose();
    super.dispose();
  }

  void _handleTap() {
    final hit = _hitNotifier.value?.hitValues.firstOrNull;
    if (hit is int) {
      widget.onDayTap?.call(hit);
    } else {
      widget.onTapEmpty?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    // The tiles are light in both themes, so the data on top of them is
    // too: the light ramp and a white halo, never the app's own surface
    // colour, which would be black ink on a beige map at night.
    final pointsByDay = widget.pointsByDay;
    final moodByDay = widget.moodByDay;

    final lines = <Polyline>[];
    final allPoints = <LatLng>[];
    final coordsByDay = <int, List<LatLng>>{};
    for (final day in pointsByDay.keys.toList()..sort()) {
      final points = [...pointsByDay[day]!]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (points.length < 2) continue;

      final coords =
          points.map((p) => LatLng(p.latitude, p.longitude)).toList();
      allPoints.addAll(coords);
      coordsByDay[day] = coords;

      final mood = moodByDay[day];
      lines.add(Polyline(
        points: coords,
        strokeWidth: 3,
        color: moodColor(mood, isDark: false),
        // A white halo, not a darker casing: it lifts the route off the
        // warm tiles and keeps two days that share a street readable as two
        // lines instead of one thick one.
        borderStrokeWidth: 1.5,
        borderColor: Colors.white.withValues(alpha: 0.85),
        pattern: mood == null
            ? StrokePattern.dashed(segments: const [6, 5])
            : const StrokePattern.solid(),
        hitValue: day,
      ));
    }

    final markers = _dayMarkers(coordsByDay, moodByDay, allPoints);

    if (allPoints.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Text('Keine Standortdaten in diesem Monat.',
            style: TEXT_STYLE_STATUS),
      );
    }

    final map = FlutterMap(
      key: ValueKey('${widget.monthKey}-${widget.expanded}'),
      options: MapOptions(
        // Must be the map's own tap hook, not a wrapping GestureDetector:
        // FlutterMap registers a TapGestureRecognizer unconditionally (only
        // the *drag* recognizers are behind `dragEnabled`), and as the
        // innermost arena member it wins every tap — an outer detector would
        // simply never fire.
        onTap: (_, _) => _handleTap(),
        initialCameraFit: CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(allPoints),
          padding: const EdgeInsets.all(24),
          maxZoom: 15,
        ),
        interactionOptions: InteractionOptions(
          // Inline the map must not drag: it sits in a vertically scrolling
          // list that is itself wrapped in a horizontal month-swipe detector,
          // and a pannable map would swallow both. Fullscreen it owns the
          // screen — but north stays up: `InteractiveFlag.all` includes
          // rotate, and a two-finger zoom then tilts the map off-north by
          // accident, which is disorienting and never what you wanted.
          flags: widget.expanded
              ? InteractiveFlag.all & ~InteractiveFlag.rotate
              : InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom,
        ),
      ),
      children: [
        // Esri's World Street Map: warm land, blue water, quiet road
        // hierarchy, labels that stay legible under the routes — a style
        // drawn by cartographers, which no colour filter over the default
        // OSM tiles ever came close to. Note the {z}/{y}/{x} order, which is
        // Esri's, not OSM's.
        TileLayer(
          urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/'
              'World_Street_Map/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: 'com.catchingclouds.marslog',
          // Neither Esri nor OSM serves @2x tiles, so flutter_map simulates
          // retina by fetching one zoom level deeper and scaling it down.
          // Costs a tile round or two, and is the difference between crisp
          // hairline streets and a blurry smear on a phone screen.
          retinaMode: RetinaMode.isHighDensity(context),
        ),
        PolylineLayer(polylines: lines, hitNotifier: _hitNotifier),
        MarkerLayer(markers: markers),
      ],
    );

    if (widget.expanded) return map;

    return SizedBox(
      height: 240,
      child: Container(
        // The thin outline frame of the Mars slide style: the pale map has no
        // edge of its own, so without it the tiles just fade into the page.
        decoration: BoxDecoration(
          border: Border.all(color: COLOR_SECONDARY.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(4),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(child: map),
            // Sits above the map, so it is hit-tested first and its tap wins
            // over the map's own recognizer.
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: widget.onTapEmpty,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  // Sits *on the map*, so it takes the map's ink, not the
                  // theme's — a white icon would vanish on the light tiles
                  // in dark mode.
                  child: const Icon(Icons.open_in_full,
                      size: 18, color: Color(0xCC000000)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One numbered dot per day, so days are told apart by reading rather than
  /// by hitting a 2px line.
  ///
  /// Placed at the day's point **furthest from the month's centre of mass**,
  /// not at its first point: fixes pile up wherever you sleep, so anchoring
  /// on the start of the day would stack every marker of the month on the
  /// same spot. The outlying point is the one that actually distinguishes a
  /// day from the others.
  List<Marker> _dayMarkers(
    Map<int, List<LatLng>> coordsByDay,
    Map<int, double> moodByDay,
    List<LatLng> allPoints,
  ) {
    if (allPoints.isEmpty) return const [];

    var sumLat = 0.0;
    var sumLng = 0.0;
    for (final p in allPoints) {
      sumLat += p.latitude;
      sumLng += p.longitude;
    }
    final centreLat = sumLat / allPoints.length;
    final centreLng = sumLng / allPoints.length;

    final markers = <Marker>[];
    for (final entry in coordsByDay.entries) {
      var anchor = entry.value.first;
      var furthest = -1.0;
      for (final p in entry.value) {
        final dLat = p.latitude - centreLat;
        final dLng = p.longitude - centreLng;
        final distance = dLat * dLat + dLng * dLng;
        if (distance > furthest) {
          furthest = distance;
          anchor = p;
        }
      }

      final day = entry.key;
      final color = moodColor(moodByDay[day], isDark: false);
      markers.add(Marker(
        point: anchor,
        // The tap target is the full 28px; the dot itself is inset, so the
        // markers stay small and the month doesn't read as a field of blobs.
        width: 28,
        height: 28,
        child: GestureDetector(
          onTap: () => widget.onDayTap?.call(day),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                // A ring in the surface colour keeps overlapping markers
                // readable as separate dots — wider than a hairline so it
                // also separates the dot from the line running under it.
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              alignment: Alignment.center,
              child: Text(
                '$day',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w400,
                  height: 1,
                  // Fixed white: every step of both ramps clears 3:1 against
                  // the surface, and the mid steps are dark enough that white
                  // is the readable choice on all of them.
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ));
    }
    return markers;
  }
}

/// Reads the mood scale: ten swatches from bad to good, labelled at the ends
/// only. Labels stay in secondary ink — text never wears the data colour.
class MoodScaleLegend extends StatelessWidget {
  const MoodScaleLegend({super.key});

  @override
  Widget build(BuildContext context) {
    // Always the light ramp: this legend only ever reads the mood map, and
    // the map's tiles are light in both themes.
    const scale = MOOD_SCALE_LIGHT;

    return Row(
      children: [
        Text('0', style: TEXT_STYLE_STATUS),
        const SizedBox(width: 8),
        // Ten steps, so each swatch flexes rather than taking a fixed width.
        for (final color in scale)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Container(height: 3, color: color),
            ),
          ),
        const SizedBox(width: 6),
        Text('10', style: TEXT_STYLE_STATUS),
      ],
    );
  }
}
