'use client';

import { Badge } from '@/components/ui/badge';
import { Card, CardContent } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Button } from '@/components/ui/button';
import { formatCurrency, formatDateTime, formatId } from '@/lib/utils';
import { Order } from '@/types';
import Image from 'next/image';
import Link from 'next/link';
import { useToast } from '@/hooks/use-toast';
import { useTransition } from 'react';
import { PayPalButtons, PayPalScriptProvider, usePayPalScriptReducer } from '@paypal/react-paypal-js';
import { createPaypalOrder, approvePaypalOrder, updateOrderToPaidCOD, deliverOrder } from '@/lib/actions/order.actions';
import StripePayment from './stripe-payment';

type OrderDetailsTableProps = {
  order: Order;
  paypalClientId: string;
  isAdmin: boolean;
  stripeClientSecret: string | null;
}


const OrderDetailsTable = ({ order, paypalClientId, isAdmin, stripeClientSecret }: OrderDetailsTableProps) => {
  const {
    id,
    shippingAddress,
    orderitems,
    itemsPrice,
    shippingPrice,
    taxPrice,
    totalPrice,
    paymentMethod,
    isDelivered,
    paidAt,
    isPaid,
    deliveredAt,
  } = order;

  const { toast } = useToast();

  const PrintLoadingState = () => {
    const [{ isPending, isRejected }] = usePayPalScriptReducer();
    let status = '';

    if (isPending) {
      status = 'Loading PayPal...';
    } else if (isRejected) {
      status = 'Error Loading PayPal';
    }

    return status;
  };

  const handleCreatePaypalOrder = async () => {
    const res = await createPaypalOrder(order.id);
    if (!res.success) {
      toast({
        variant: 'destructive',
        description: res.message,
      });
    }

    return res.data;
  };

  const handleApprovePaypalOrder = async (data: { orderID: string }) => {
    const res = await approvePaypalOrder(order.id, data);
    toast({
      variant: res.success ? 'default' : 'destructive',
      description: res.message,
    });
  };

  // Button to mark order as paid
  const MarkAsPaidButton = () => {
    const [isPending, startTransition] = useTransition();
    const { toast } = useToast();

    return (
      <Button
        type="button"
        disabled={isPending}
        onClick={() => startTransition(async () => {
          const res = await updateOrderToPaidCOD(order.id);
          toast({
            variant: res.success ? 'default' : 'destructive',
            description: res.message,
          });
        })}>
        {isPending ? 'Processing...' : 'Mark As Paid'}
      </Button>
    );
  };

  // Button to mark order as delivered
  const MarkAsDeliveredButton = () => {
    const [isPending, startTransition] = useTransition();
    const { toast } = useToast();

    return (
      <Button
        type="button"
        disabled={isPending}
        onClick={() => startTransition(async () => {
          const res = await deliverOrder(order.id);
          toast({
            variant: res.success ? 'default' : 'destructive',
            description: res.message,
          });
        })}>
        {isPending ? 'Processing...' : 'Mark As Delivered'}
      </Button>
    );
  };

  return (
    <>
      <h1 className="py-4 text-2xl"> Order {formatId(id)}</h1>
      <div className="grid md:grid-cols-3 md:gap-5">
        <div className="col-span-2 space-4-y overflow-x-auto">
          <Card>
            <CardContent className="p-4 gap-4">
              <h2 className="text-xl pb-4">Payment Method</h2>
              <p>{paymentMethod}</p>
              {isPaid ? (
                <Badge variant="secondary">
                  Paid at {formatDateTime(paidAt!).dateTime}
                </Badge>
              ) : (
                <Badge variant="destructive">
                  Not Paid
                </Badge>
              )}
            </CardContent>
          </Card>
          <Card className="my-2">
            <CardContent className="p-4 gap-4">
              <h2 className="text-xl pb-4 mb-1">Shipping Address</h2>
              <p>{shippingAddress.fullName}</p>
              <p>{shippingAddress.streetAddress}, {shippingAddress.city}, {shippingAddress.postalCode}, {shippingAddress.country}</p>
              {isDelivered ? (
                <Badge variant="secondary">
                  Delivered at {formatDateTime(deliveredAt!).dateTime}
                </Badge>
              ) : (
                <Badge variant="destructive">
                  Not Delivered
                </Badge>
              )}
            </CardContent>
          </Card>
          <Card className="my-2">
            <CardContent className="p-4 gap-4">
              <h2 className="text-xl">Order Items</h2>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead> Item </TableHead>
                    <TableHead> Quantity </TableHead>
                    <TableHead> Price </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {orderitems.map((item) => (
                    <TableRow key={item.slug}>
                      <TableCell>
                        <Link href={`/product/${item.slug}`}
                              className="flex items-center">
                          <Image src={item.image}
                                 alt={item.slug}
                                 width={50}
                                 height={50}/>
                          <span className="px-2">{item.name}</span>
                        </Link>
                      </TableCell>
                      <TableCell>
                        <span className="px-2">{item.qty}</span>
                      </TableCell>
                      <TableCell>
                        <span className="text-right">${item.price}</span>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
        </div>
        <div>
          <Card>
            <CardContent className="p-4 gap-4 space-y-4">
              <div className="flex justify-between">
                <div> Items</div>
                <div> {formatCurrency(itemsPrice)}</div>
              </div>
              <div className="flex justify-between">
                <div> Tax</div>
                <div> {formatCurrency(taxPrice)}</div>
              </div>
              <div className="flex justify-between">
                <div> Shipping</div>
                <div> {formatCurrency(shippingPrice)}</div>
              </div>
              <div className="flex justify-between">
                <div> Total</div>
                <div> {formatCurrency(totalPrice)}</div>
              </div>

              {/* PayPal Payment */}
              {!isPaid && paymentMethod === 'PayPal' && (
                <div>
                  <PayPalScriptProvider options={{ clientId: paypalClientId }}>
                    <PrintLoadingState/>
                    <PayPalButtons createOrder={handleCreatePaypalOrder}
                                   onApprove={handleApprovePaypalOrder}/>
                  </PayPalScriptProvider>
                </div>
              )}

              {/* Stripe Payment */}
              {!isPaid && paymentMethod === 'Stripe' && stripeClientSecret && (
                <StripePayment
                  priceInCents={Math.round(Number(order.totalPrice) * 100)}
                  orderId={order.id}
                  clientSecret={stripeClientSecret}
                />
              )}

              {/* Cash on Delivery */}
              {isAdmin && !isPaid && paymentMethod === 'CashOnDelivery' && (
                <MarkAsPaidButton/>
              )}
              {isAdmin && isPaid && !isDelivered && (
                <MarkAsDeliveredButton/>
              )}
            </CardContent>
          </Card>
        </div>
      </div>
    </>
  );
};

export default OrderDetailsTable;