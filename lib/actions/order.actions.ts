'use server';

import { auth } from '@/auth';
import { prisma } from '@/db/prisma';
import { sendPurchaseReceipt } from '@/email';
import { getMyCart } from '@/lib/actions/cart.actions';
import { getUserById } from '@/lib/actions/user.actions';
import { convertToPlainObject, formatError } from '@/lib/utils';
import { insertOrderSchema } from '@/lib/validators';
import { CartItem, PaymentResult, ShippingAddress } from '@/types';
import { Prisma } from '@prisma/client';
import { isRedirectError } from 'next/dist/client/components/redirect-error';
import { paypal } from '@/lib/paypal';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { PAGE_SIZE } from '@/lib/constants';


// Create order and order items
export async function createOrder() {
  try {
    const session = await auth();
    if (!session) throw new Error('User is not authenticated');

    const userId = session?.user?.id;
    if (!userId) throw new Error('User not found');

    const user = await getUserById(userId);
    const cart = await getMyCart();

    if (!cart || cart.items.length === 0) {
      return {
        success: false,
        message: 'Your cart is empty',
        redirectTo: '/cart',
      };
    }

    if (!user.address) {
      return {
        success: false,
        message: 'No shipping address',
        redirectTo: '/shipping-address',
      };
    }

    if (!user.paymentMethod) {
      return {
        success: false,
        message: 'No payment method',
        redirectTo: '/payment-method',
      };
    }

    // create order object
    const order = insertOrderSchema.parse({
      userId: user.id,
      shippingAddress: user.address,
      paymentMethod: user.paymentMethod,
      itemsPrice: cart.itemsPrice,
      shippingPrice: cart.shippingPrice,
      taxPrice: cart.taxPrice,
      totalPrice: cart.totalPrice,
    });

    // create a transaction to create order and order items in db
    const insertedOrderId = await prisma.$transaction(async (tx) => {
      const insertedOrder = await tx.order.create({ data: order });

      for (const item of cart.items as CartItem[]) {
        await tx.orderItem.create({
          data: {
            ...item,
            price: item.price,
            orderId: insertedOrder.id,
          },
        });
      }

      // clear cart
      await tx.cart.update({
        where: { id: cart.id },
        data: {
          items: [],
          totalPrice: 0,
          shippingPrice: 0,
          taxPrice: 0,
          itemsPrice: 0,
        },
      });

      return insertedOrder.id;
    });

    if (!insertedOrderId) throw new Error('Order not created');

    return {
      success: true,
      message: 'Order created',
      redirectTo: `/order/${insertedOrderId}`,
    };
  } catch (error) {
    if (isRedirectError(error)) throw new Error;
    return {
      success: false,
      message: formatError(error),
    };
  }
}

// Get order by id
export async function getOrderById(orderId: string) {
  const uuidSchema = z.string().uuid();
  // return null immediately on invalid UUID
  if (!uuidSchema.safeParse(orderId).success) {
      return null;
  }

  const data = await prisma.order.findFirst({
    where: {
      id: orderId,
    },
    include: {
      orderitems: true,
      user: { select: { name: true, email: true } },
    },
  });

  return convertToPlainObject(data);
}

export async function createPaypalOrder(orderId: string) {
  try {
    const order = await prisma.order.findFirst({
      where: { id: orderId },
    });

    if (order) {
      //create PayPal order
      const paypalOrder = await paypal.createOrder(Number(order.totalPrice));
      await prisma.order.update({
        where: { id: orderId },
        data: {
          paymentResult: {
            id: paypalOrder.id,
            email_address: '',
            status: '',
            pricePaid: 0,
          },
        },
      });

      return {
        success: true,
        message: 'Item order created successfully',
        data: paypalOrder.id,
      };
    } else {
      throw new Error('Order not Found');
    }
  } catch (error) {
    return {
      success: false, message: formatError(error),
    };
  }
}

// Approve paypal order and update isPaid and paidAt
export async function approvePaypalOrder(orderId: string,
  data: { orderID: string }) {
  try {
    const order = await prisma.order.findFirst({
      where: { id: orderId },
    });

    if (!order) throw new Error('Order not Found');

    const captureData = await paypal.capturePayment(data.orderID);

    if (!captureData || captureData.id !== (order.paymentResult as PaymentResult)?.id || captureData.status !== 'COMPLETED') {
      throw new Error('Error in PayPal payment');
    }

    await updateOrderToPaid({
      orderId,
      paymentResult: {
        id: captureData.id,
        status: captureData.status,
        email_address: captureData.payer.email_address,
        pricePaid: captureData.purchase_units[0]?.payments.captures[0]?.amouint?.value,
      },
    });

    revalidatePath(`/order/${orderId}`);
    return {
      success: true, message: 'Your order has been paid',
    };
  } catch (error) {
    return {
      success: false, message: formatError(error),
    };
  }
}

//update order to pay
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

// get users orders
export async function getMyOrders({ limit = PAGE_SIZE, page }: { limit?: number, page: number }) {
  const session = await auth();
  if (!session) throw new Error('User is not authorized');

  const data = await prisma.order.findMany({
    where: { userId: session?.user?.id },
    orderBy: { createdAt: 'desc' },
    take: limit,
    skip: (page - 1) * limit,
  });

  const dataCount = await prisma.order.count({
    where: { userId: session?.user?.id },
  });

  return {
    data,
    totalPages: Math.ceil(dataCount / limit),
  };
}

type SalesDataType = {
  month: string;
  totalSales: number
}[];

// get sales data and order summary
export async function getOrderSummary() {
  // get counts for each resource
  const ordersCount = await prisma.order.count();
  const productsCount = await prisma.product.count();
  const usersCount = await prisma.user.count({
    where: {
      role: { not: 'admin' },
    },
  });

  // calculate the total sales
  const totalSales = await prisma.order.aggregate({
    _sum: { totalPrice: true },
  });

  // get monthly sales
  const salesDataRaw = await prisma.$queryRaw<Array<{ month: string; totalSales: Prisma.Decimal }
  >>`SELECT to_char("createdAt", 'MM/YY') as "month", sum("totalPrice") as "totalSales"
     FROM "Order"
     GROUP BY to_char("createdAt", 'MM/YY')`;

  const salesData: SalesDataType = salesDataRaw.map((entry) => ({
    month: entry.month,
    totalSales: Number(entry.totalSales),
  }));
  // get latest sales
  const latesSalesData = await prisma.order.findMany({
    orderBy: {
      createdAt: 'desc',
    },
    include: {
      user: { select: { name: true } },
    },
    take: 6,
  });

  return {
    ordersCount,
    productsCount,
    usersCount,
    totalSales,
    latesSalesData,
    salesData,
  };
}

// get all orders
export async function getAllOrders({ limit = PAGE_SIZE, page, query }: { limit?: number, page: number, query: string }) {
  const queryFilter: Prisma.OrderWhereInput = query && query !== 'all' ? {
    user: {
      name: {
        contains: query,
        mode: 'insensitive'
      } as Prisma.StringFilter
    }
  } : {};

  const data = await prisma.order.findMany({
    where: {
      ...queryFilter,
    },
    orderBy: { createdAt: 'desc' },
    take: limit,
    skip: (page - 1) * limit,
    include: { user: { select: { name: true } } }
  });

  const dataCount = await prisma.order.count();

  return {
    data,
    totalPages: Math.ceil(dataCount / limit),
  };
}

// delete order
export async function deleteOrder(orderId: string) {
  try {
    await prisma.order.delete({
      where: {
        id: orderId,
      },
    });

    revalidatePath('/admin/orders');

    return {
      success: true,
      message: 'Order deleted successfully',
    };
  } catch (error) {

    return {
      success: false,
      message: formatError(error),
    };
  }
}

// update COD order to pay
export async function updateOrderToPaidCOD(orderId: string) {
  try {
    await updateOrderToPaid({ orderId });

    revalidatePath(`/order/${orderId}`);

    return {
      success: true,
      message: 'Order marked as paid',
    };
  } catch (error) {
    return {
      success: false,
      message: formatError(error),
    };
  }
}

// update COD order to delivered
export async function deliverOrder(orderId: string) {
  try {
    const order = await prisma.order.findFirst({
      where: {
        id: orderId,
      },
    });

    if (!order) throw new Error('Order not found');
    if (!order?.isPaid) throw new Error('Order is not paid');

    await prisma.order.update({
      where: { id: orderId },
      data: {
        isDelivered: true,
        deliveredAt: new Date(),
      },
    });

    revalidatePath(`/order/${orderId}`);

    return {
      success: true,
      message: 'Order marked as delivered',
    };
  } catch (error) {
    return {
      success: false,
      message: formatError(error),
    };
  }
}