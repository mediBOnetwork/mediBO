// Always returns the plural form of packType (e.g. Strip→Strips, Vial→Vials).
// Returns '' when packType is null/empty.
String packLabel(int qty, String? packType) {
  final pt = (packType ?? '').trim();
  if (pt.isEmpty) return '';
  const irregular = <String, String>{
    'Box': 'Boxes',
    'Patch': 'Patches',
  };
  if (irregular.containsKey(pt)) return irregular[pt]!;
  if (pt.endsWith('s')) return pt;
  return '${pt}s';
}

String qtyPillLabel(int qty, String? packType) {
  final pl = packLabel(qty, packType);
  return pl.isEmpty ? 'Qty $qty' : 'Qty $qty $pl';
}
