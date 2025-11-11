import { auth } from '@/auth';
import { Metadata } from 'next';
import { getOrderById } from '@/lib/actions/order.actions';
import { notFound } from 'next/navigation';
import { ShippingAddress } from '@/types';
import OrderDetailsTable from './order-details-table';
import Stripe from 'stripe';


export const metadata: Metadata = {
  title: 'Order Details',
};


const OrderDetailsPage = async (props: {
  params: Promise<{ id: string }>
}) => {
  const { id } = await props.params;

  const order = await getOrderById(id);
  if (!order) notFound();

  const session = await auth();

  let clientSecret = null;

  // Check if is not paid and payment method is stripe
  if (!order.isPaid && order.paymentMethod === 'Stripe') {
    // Initialize Stripe
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY as string);
    // Create a PaymentIntent
    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(Number(order.totalPrice * 100)), // amount in cents
      currency: 'USD',
      metadata: { orderId: order.id },
    });
    clientSecret = paymentIntent.client_secret;
  }

  return (
    <OrderDetailsTable
      order={{ ...order, shippingAddress: order.shippingAddress as ShippingAddress }}
      stripeClientSecret={clientSecret}
      paypalClientId={process.env.PAYPAL_CLIENT_ID || 'sb'}
      isAdmin={ session?.user?.role === 'admin' || false}
    />
  );
};

export default OrderDetailsPage;