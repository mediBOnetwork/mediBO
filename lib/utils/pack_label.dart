String packLabel(int qty, String? packType) {
  final pt = (packType ?? '').trim();
  if (pt.isEmpty) return '';
  if (qty <= 1) return pt;
  const irregular = <String, String>{
    'Box': 'Boxes',
    'Patch': 'Patches',
  };
  if (irregular.containsKey(pt)) return irregular[pt]!;
  if (pt.endsWith('s')) return pt;
  return '${pt}s';
}
