#!/usr/bin/env python3
# CHANGE #1016 — the shell wiring, as a script, because lib/screens/home_shell.dart
# was leased by another command for the whole of this build (Layer 3, CHANGE #327).
#
# Run from the repo root, ONCE, the moment the lease frees:
#     python3 scripts/c1016_shell_patch.py && flutter test test/protected/admin_nav_reachability_test.dart
#
# Every anchor is asserted, so a shell that has moved on fails loudly instead of
# patching the wrong place. It adds: the staff_nav() listener/loader, the
# nav_redirect hop in _handleAdminNav, the Money (13) and More (14) home pages,
# the staff-shard lookup that opens the seven partner doors and Stuck work, the
# Customers/Suppliers/Fulfill strips, and the bar entries from staff_nav().
p='lib/screens/home_shell.dart'
s=open(p).read()
def rep(old,new,count=1):
    global s
    assert s.count(old)>=1, 'anchor missing: '+old[:60]
    s=s.replace(old,new,count)
rep("import 'shell/shell_extra_routes.dart';             // CHANGE #570 — four doors\n",
    "import 'shell/shell_extra_routes.dart';             // CHANGE #570 — four doors\nimport 'shell/shell_staff_routes.dart';             // CHANGE #1016 — six verbs\nimport '../services/staff_nav.dart';                 // CHANGE #1016\n")
rep("    Access.instance.addListener(_onAccessChanged); // C653\n",
    "    Access.instance.addListener(_onAccessChanged); // C653\n    StaffNav.value.addListener(_onAccessChanged); // CHANGE #1016 — the bar\n")
rep("    CustomerNav.load();\n", "    CustomerNav.load();\n    StaffNav.load(); // CHANGE #1016 — staff_nav(): tabs, redirects, layout\n")
rep("    CustomerNav.syncIdentity();\n", "    CustomerNav.syncIdentity();\n    StaffNav.syncIdentity(); // CHANGE #1016\n")
rep("    Access.instance.removeListener(_onAccessChanged); // C653\n",
    "    Access.instance.removeListener(_onAccessChanged); // C653\n    StaffNav.value.removeListener(_onAccessChanged); // CHANGE #1016\n")
rep("  void _handleAdminNav(String route, [String? seed]) {\n    if (!mounted) return;\n",
    "  void _handleAdminNav(String route, [String? seed]) {\n    if (!mounted) return;\n    route = shellResolveStaffRoute(route, seed); // CHANGE #1016 — nav_redirect\n")
# ops_queues block -> staff shard; add the two homes + the staff shard lookup
start=s.index("      case 'ops_queues':\n")
end=s.index("      case 'logout':\n")
block=s[start:end]
assert 'AdminOpsQueuesScreen' in block
s=s[:start]+("      // CHANGE #1016 — the Money and More homes (staff_home), and the staff\n"
             "      // shard: the partner doors + Stuck work (ops_queues) moved there.\n"
             "      case 'money_home': setState(() { _index = 13; _cartOpen = false; }); break;\n"
             "      case 'more': setState(() { _index = 14; _cartOpen = false; }); break;\n"
             "      case _ when shellStaffRouteScreen(route) != null:\n"
             "        Navigator.push(context, MaterialPageRoute(\n"
             "            builder: (_) => shellStaffRouteScreen(route)!));\n"
             "        break;\n")+s[end:]
rep("          adminPage(() => AdminSupplierScreen()),\n          adminPage(() => AdminCustomerScreen()),\n",
    "          // CHANGE #1016 — the home's extra doors ride above the page's own tabs.\n"
    "          adminPage(() => shellWithStaffStrip('suppliers', AdminSupplierScreen(), _handleAdminNav)),\n"
    "          adminPage(() => shellWithStaffStrip('customers', AdminCustomerScreen(), _handleAdminNav)),\n")
rep("          adminPage(() => QuickLinkNavigator(\n                navigate: _handleAdminNav,\n                child: AdminFulfillmentScreen(\n                    allowedTabs:\n                        Access.instance.allowedTabIndexes('fulfillment')))),\n",
    "          adminPage(() => shellWithStaffStrip('fulfill', QuickLinkNavigator(\n                navigate: _handleAdminNav,\n                child: AdminFulfillmentScreen(\n                    allowedTabs:\n                        Access.instance.allowedTabIndexes('fulfillment'))), _handleAdminNav)),\n")
rep("          CatalogueScreen(active: _index == 12),\n",
    "          CatalogueScreen(active: _index == 12),\n"
    "          // CHANGE #1016 — index 13 Money, index 14 More: staff_home() rendered.\n"
    "          adminPage(() => shellStaffHomePage('money', _index == 13, _handleAdminNav)),\n"
    "          adminPage(() => shellStaffHomePage('more', _index == 14, _handleAdminNav)),\n")
rep("                  kAdminBottomNav, Access.instance.routeCanView),\n",
    "                  shellStaffBarEntries(kAdminBottomNav), Access.instance.routeCanView),\n")
rep("                      kAdminTopNav, Access.instance.routeCanView),\n",
    "                      shellStaffBarEntries(kAdminTopNav), Access.instance.routeCanView),\n")
open(p,'w').write(s)
print('patched; lines =', s.count('\n'))
