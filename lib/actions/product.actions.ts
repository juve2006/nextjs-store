'use server';
import { PrismaClient } from '@prisma/client';
import { LATEST_PRODUCTS_LIMIT } from '@/lib/constants';

export async function getLatestProducts() {
  const prisma = new PrismaClient();

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