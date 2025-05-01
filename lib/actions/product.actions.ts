'use server';
import { prisma } from '@/db/prisma';
import { LATEST_PRODUCTS_LIMIT } from '@/lib/constants';

export async function getLatestProducts() {
  const products = await prisma.product.findMany({
    take: LATEST_PRODUCTS_LIMIT,
    orderBy: {
      createdAt: 'desc',
    },
  });

  return products.map((product) => ({
    ...product,
    price: product.price.toString(),
    rating: product.rating.toString(),
  }));
}