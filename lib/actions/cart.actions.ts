'use server';

import { auth } from '@/auth';
import { prisma } from '@/db/prisma';
import { cartItemSchema, insertCartSchema } from '@/lib/validators';
import { Prisma } from '@prisma/client';
import { revalidatePath } from 'next/cache';
import { cookies } from 'next/headers';
import { CartItem } from '@/types';
import { convertToPlainObject, formatError, round2 } from '@/lib/utils';

//calculate cart prices
const calcPrice = (items: CartItem[]) => {
  const itemsPrice = round2(
    items.reduce((acc, item) => acc + Number(item.price) * item.qty, 0),
  );
  const shippingPrice = round2(itemsPrice > 100 ? 0 : 10);
  const taxPrice = round2(0.15 * itemsPrice);
  const totalPrice = round2(itemsPrice + shippingPrice + taxPrice);

  return {
    itemsPrice: itemsPrice.toFixed(2),
    shippingPrice: shippingPrice.toFixed(2),
    taxPrice: taxPrice.toFixed(2),
    totalPrice: totalPrice.toFixed(2),
  }
}

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

    if (!product) {
      throw new Error('Product not found');
    }

    if (!cart) {
      //create new cart object
      const newCart = insertCartSchema.parse({
        userId: userId,
        items: [item],
        sessionCartId: sessionCartId,
        ...calcPrice([item]),
      })

      await prisma.cart.create({
        data: newCart,
      });

      //revalidate product page
      revalidatePath(`/product/${product.slug}`);

      return {
        success: true,
        message: `${product.name} added successfully`,
      };
    } else {
      //check if item is already in cart
      const existItem = (cart.items as CartItem[]).find((cartItem) => cartItem.productId === item.productId);

      if(existItem) {
        //check stock
        if (product.stock < existItem.qty) {
          throw new Error('Not enough stock');
        }
        //increase the quantity
        (cart.items as CartItem[]).find((cartItem) => cartItem.productId === item.productId)!.qty = existItem.qty + 1;
      } else {
        //if item does not exist in cart
        //check stock
        if (product.stock < 1) {
          throw new Error('Not enough stock');
        }
        //add item to the cart.items
        cart.items.push(item)
      }
      //save to db
      await prisma.cart.update({
        where: { id: cart.id },
        data: {
          items: cart.items as Prisma.CartUpdateitemsInput[],
          ...calcPrice(cart.items as CartItem[]),
        }
      })

      revalidatePath(`/product/${product.slug}`);
      console.log(existItem)
      return {
        success: true,
        message: `${product.name} ${existItem ? 'updated in' : 'added to'} cart`,
      }
    }

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