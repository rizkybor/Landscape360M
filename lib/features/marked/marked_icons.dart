import 'package:flutter/material.dart';

import '../../domain/marked/marked_locations.dart';

// Icons of the marked-location categories, the Material equivalents of the web's
// (src/utils/markedLocationIcons.ts)

const markedCategoryIcons = <MarkedLocationCategory, IconData>{
  MarkedLocationCategory.poi: Icons.place,
  MarkedLocationCategory.camp: Icons.holiday_village_outlined,
  MarkedLocationCategory.summit: Icons.landscape,
  MarkedLocationCategory.water: Icons.water_drop,
  MarkedLocationCategory.shelter: Icons.house_outlined,
  MarkedLocationCategory.viewpoint: Icons.visibility_outlined,
  MarkedLocationCategory.trailhead: Icons.flag_outlined,
  MarkedLocationCategory.hazard: Icons.warning_amber,
  MarkedLocationCategory.cave: Icons.door_front_door_outlined,
  MarkedLocationCategory.parking: Icons.local_parking,
};

Color markedCategoryColor(MarkedLocationCategory c) => Color(c.color);
