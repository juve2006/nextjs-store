import { prisma } from '@/db/prisma';
import { sendPurchaseReceipt } from '@/email';
import { PaymentResult, ShippingAddress } from '@/types';

// Not in a 'use server' file on purpose: exports there become public server actions,
// and this marks orders paid without checking payment. Call only after verifying payment.
export async function updateOrderToPaid({ orderId, paymentResult }: { orderId: string, paymentResult?: PaymentResult }) {
  const order = await prisma.order.findFirst({
    where: { id: orderId },
    include: { orderitems: true },
  });

  if (!order) throw new Error('Order not Found');
  if (order.isPaid) throw new Error('Order is already paid');

  // Transaction to update order and account for product stock
  await prisma.$transaction(async (tx) => {
    // iterate over products and update stock
    for (const item of order.orderitems) {
      await tx.product.update({
        where: { id: item.productId },
        data: {
          stock: {
            increment: -item.qty,
          },
        },
      });
    }
    // set order to pay
    await tx.order.update({
      where: { id: orderId },
      data: {
        isPaid: true,
        paidAt: new Date(),
        paymentResult: paymentResult,
      },
    });
  });

  // get updated order after transaction
  const updatedOrder = await prisma.order.findFirst({
    where: {
      id: orderId,
    },
    include: {
      orderitems: true,
      user: {
        select: {
          name: true,
          email: true,
        },
      },
    },
  });
  if (!updatedOrder) throw new Error('Order not found');

  await sendPurchaseReceipt({
    order: {
      ...updatedOrder,
      shippingAddress: updatedOrder.shippingAddress as ShippingAddress,
      paymentResult: updatedOrder.paymentResult as PaymentResult
    }
  })
}
