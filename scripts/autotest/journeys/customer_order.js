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
    // The card's own vocabulary, not a guess: a feed item is `id` + the
    // `availability` block the compact card reads, whose can_add IS the
    // backend's decision about whether this line may be added at all. The
    // first version of this walked for `product_id` + `pricing.can_add`,
    // matched nothing in 596 real cards, and reported "nothing to order"
    // about a storefront that was offering 562 buyable ones.
    const ids = [];
    const walk = (node) => {
      if (!node || typeof node !== 'object') return;
      if (Array.isArray(node)) { node.forEach(walk); return; }
      const av = node.availability;
      if (node.id && node.buyable && av && av.can_add === true) {
        ids.push(String(node.id));
      }
      Object.values(node).forEach(walk);
    };
    walk(home);
    if (!ids.length) {
      // Nothing addable is a PRECONDITION the bot cannot create, not a bug in
      // the order path — proven at the RPC as well as the card: cart_set_item
      // on a zone-99 product refuses with this same sentence. So it reports
      // BLOCKED, carrying the backend's own refusal verbatim plus the counts,
      // because "nothing to order" that does not say what it saw sends the
      // next person back through the whole browser journey to learn one number.
      let cards = 0;
      let reason = '';
      const count = (node) => {
        if (!node || typeof node !== 'object') return;
        if (Array.isArray(node)) { node.forEach(count); return; }
        if (node.id && node.name && node.availability) {
          cards += 1;
          if (!reason && node.availability.note) reason = String(node.availability.note);
        }
        Object.values(node).forEach(count);
      };
      count(home);
      return { ok: false, blocked: true, note:
        `${reason || 'no addable product'} — ` +
        `sections=${((home || {}).sections || []).length} cards=${cards} addable=0` };
    }
    const id = ids[0];
    fs_.scratch.productId = id;
    // cart_set_item(p_product_id text, p_quantity int) — the parameter is
    // p_quantity, and PostgREST resolves by exact parameter NAMES, so a
    // wrong one is a 404 rather than a default.
    fs_.scratch.rpcArgs = Object.assign({}, fs_.scratch.rpcArgs, {
      cart_set_item: { p_product_id: id, p_quantity: 1 }
    });
    return { ok: true, note: `picked product ${id} from the live storefront` };
  });
}

module.exports = { register };
