import { NextRequest, NextResponse } from 'next/server';
import Stripe from 'stripe';
import { updateOrderToPaid } from '@/lib/actions/order.actions';

export async function POST(request: NextRequest) {
  const event = await Stripe.webhooks.constructEvent(
    await request.text(),
    request.headers.get('stripe-signature'),
    process.env.STRIPE_WEBHOOK_SECRET,
  );

  if (event.type === 'charge.succeeded') {
    const { object } = event.data;

    await updateOrderToPaid({
      orderId: object.metadata.orderId,
      paymentResult: {
        id: object.id,
        status: 'COMPLETED',
        email_address: object.billing_details.email!,
        pricePaid: (object.amount / 100).toFixed(),
      },
    });

    return NextResponse.json({
      message: 'updateOrderToPaid was successful',
    });
  }

  return NextResponse.json({
    message: 'event is not charge.succeeded',
  });
}