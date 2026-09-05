'use strict';
// CHANGE #634 — the one PROVEN end-to-end: a customer places an order.
//
// It exists to prove the harness, so it deliberately does the whole thing the
// hard way: a real customer session in a real browser against the deployed
// build, a real product chosen from the real catalogue, the real cart RPCs,
// the real place_order_v2, and an END STATE the DATABASE decides
// (test_assert_order_placed). Nothing is simulated.
//
// It is safe because the run owns a test session (#573): `orders` and 56 other
// tables are stamped with it ambiently, and test_run_finish purges the lot.
//
// Only the two steps the generic vocabulary cannot express live here.
const api = require('../api');

function register(harness) {
  // Pick a real, in-stock, buyable product from the storefront the customer is
  // actually looking at. The BACKEND chooses it — storefront_home_v2 is the
  // same RPC the home feed renders — so this never hardcodes a medicine id.
  harness.registerStep('pick_product', async (fs_) => {
    const home = await api.rpc('storefront_home_v2', {}, fs_.token);
    const ids = [];
    const walk = (node) => {
      if (!node || typeof node !== 'object') return;
      if (Array.isArray(node)) { node.forEach(walk); return; }
      if (node.product_id && node.pricing && node.pricing.can_add !== false) {
        ids.push(String(node.product_id));
      }
      Object.values(node).forEach(walk);
    };
    walk(home);
    if (!ids.length) {
      return { ok: false, note: 'the storefront offered no addable product — nothing to order' };
    }
    const id = ids[0];
    fs_.scratch.productId = id;
    fs_.scratch.rpcArgs = Object.assign({}, fs_.scratch.rpcArgs, {
      cart_set_item: { p_product_id: id, p_qty: 1 }
    });
    return { ok: true, note: `picked product ${id} from the live storefront` };
  });
}

module.exports = { register };
