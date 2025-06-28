'use server';

import { auth } from '@/auth';
import { prisma } from '@/db/prisma';
import { cartItemSchema } from '@/lib/validators';
import { cookies } from 'next/headers';
import { CartItem } from '@/types';
import { convertToPlainObject, formatError } from '@/lib/utils';

export async function addItemToCart(data: CartItem) {
  try {
    //check cart cookie
    const sessionCartId = (await cookies()).get('sessionCartId')?.value;
    if (!sessionCartId) {
      throw new Error('Cart session does not exist');
    }

    //get session and user id
    const session = await auth();
    const userId = session?.user?.id ? (session?.user?.id as string) : undefined;

    //get cart
    const cart = await getMyCart();
    const item = cartItemSchema.parse(data);

    //get product
    const product = await prisma.product.findUnique({
      where: { id: item.productId },
    });

    return {
      success: true,
      message: 'Item added successfully',
    };
  } catch (error) {
    return {
      success: false,
      message: formatError(error),
    };
  }
}

export async function getMyCart() {
  const sessionCartId = (await cookies()).get('sessionCartId')?.value;
  if (!sessionCartId) {
    throw new Error('Cart session does not exist');
  }

  //get session and user id
  const session = await auth();
  const userId = session?.user?.id ? (session?.user?.id as string) : undefined;

  //get user cart
  const cart = await prisma.cart.findFirst({
    where: userId ? { userId: userId } : { sessionCartId: sessionCartId },
  });

  if (!cart) {
    return undefined;
  }

  return convertToPlainObject({
    ...cart,
    items: cart.items as CartItem[],
    itemsPrice: cart.itemsPrice.toString(),
    totalPrice: cart.totalPrice.toString(),
    shippingPrice: cart.shippingPrice.toString(),
    taxPrice: cart.taxPrice.toString(),
  });

}