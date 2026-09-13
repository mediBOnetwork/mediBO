// CMD #1849 — the outbound chokepoint, on the edge side.
//
// Every Razorpay endpoint is real money on live keys. The SQL wrappers already
// refuse a test session at rzp_checkout_prepare / rzp_qr_prepare /
// refund_prepare / rzp_reconcile_due, because an edge function cannot reach
// api.razorpay.com without first asking one of them. Account creation has no
// such prepare step, and none of them sees the CALLER's own session header, so
// this asks the one dispatcher directly and forwards that header verbatim.
//
// It decides nothing. `outbound_payment_gate` answers, and this returns its
// answer with the backend's own message.

export interface OutboundGate {
  allowed: boolean;
  decision: string;
  message: string;
  receiptId: number | null;
}

/// The header #1848 binds a person's test session to their install.
export const TEST_SESSION_HEADER = 'x-medibo-test-session';

/// `endpoint` names the Razorpay call about to be made ('account.create',
/// 'refund.create', …). `orderId` is passed when the call belongs to an order.
export async function outboundPaymentGate(
  supabaseUrl: string,
  serviceKey: string,
  req: Request,
  endpoint: string,
  orderId: string | null = null,
  amount: number | null = null,
): Promise<OutboundGate> {
  try {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
    };
    const token = req.headers.get(TEST_SESSION_HEADER);
    if (token) headers[TEST_SESSION_HEADER] = token;

    const r = await fetch(`${supabaseUrl}/rest/v1/rpc/outbound_payment_gate`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        p_endpoint: endpoint,
        p_order_id: orderId,
        p_amount: amount,
      }),
    });
    const body = await r.json().catch(() => null);
    if (!r.ok || !body || typeof body !== 'object') {
      // Fail closed on outbound: if the gate cannot answer, nothing goes to
      // Razorpay. Nothing else about the caller's request is blocked.
      return {
        allowed: false,
        decision: 'hold',
        message: '',
        receiptId: null,
      };
    }
    const b = body as Record<string, unknown>;
    return {
      allowed: b.allowed === true,
      decision: String(b.decision ?? 'hold'),
      message: String(b.message ?? ''),
      receiptId: typeof b.receipt_id === 'number' ? b.receipt_id : null,
    };
  } catch (_e) {
    return { allowed: false, decision: 'hold', message: '', receiptId: null };
  }
}
