'use server';
import { prisma } from '@/db/prisma';
import { z } from 'zod';
import { LATEST_PRODUCTS_LIMIT, PAGE_SIZE } from '@/lib/constants';
import { convertToPlainObject, formatError } from '@/lib/utils';
import { insertProductSchema, updateProductSchema } from '@/lib/validators';
import { revalidatePath } from 'next/cache';

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

// get single product by slug
export async function getProductBySlug(slug: string) {
  return await prisma.product.findFirst({
    where: {
      slug: slug,
    }
  })
}

// get single product by id
export async function getProductById(productId: string) {
  const data =  await prisma.product.findFirst({
    where: {
      id: productId,
    }
  });

  return convertToPlainObject(data);
}

// get all products
type GetAllProductsParams = {
  query: string;
  limit?: number;
  page: number;
  category?: string;
};

export async function geyAllProducts({ limit = PAGE_SIZE, page }: GetAllProductsParams) {
  const data = await prisma.product.findMany({
    orderBy: { createdAt: 'desc' },
    skip: (page - 1) * limit,
    take: limit,
  });

  const dataCount = await prisma.product.count();

  return {
    data,
    totalPages: Math.ceil(dataCount / limit),
  };
}

export async function deleteProduct(id: string) {
  try {
    const productExists = await prisma.product.findFirst({
      where: {
        id: id,
      },
    });

    if (!productExists) throw new Error('Product not found');

    await prisma.product.delete({ where: { id } });

    revalidatePath('/admin/products');

    return {
      success: true,
      message: 'Product deleted successfully',
    };
  } catch (error) {
    return {
      success: false,
      message: formatError(error),
    };
  }
}

export async function createProduct(data: z.infer<typeof insertProductSchema>) {
  try {
    const product = insertProductSchema.parse(data);

    await prisma.product.create({
      data: product,
    });

    revalidatePath('/admin/products');

    return {
      success: true,
      message: 'Product created successfully',
    };
  } catch (error) {
    return {
      success: false,
      message: formatError(error),
    };
  }
}

export async function updateProduct(data: z.infer<typeof updateProductSchema>) {
  try {
    const product = updateProductSchema.parse(data);
    const productExists = await prisma.product.findFirst({
      where: {
        id: product.id,
      },
    });

    if (!productExists) throw new Error('Product not found');

    await prisma.product.update({
      where: {
        id: product.id,
      },
      data: product,
    });

    revalidatePath('/admin/products');

    return {
      success: true,
      message: 'Product created successfully',
    };
  } catch (error) {
    return {
      success: false,
      message: formatError(error),
    };
  }
}

// get all categories
export async function getAllCategories() {
  const data = await prisma.product.groupBy({
    by: ['category'],
    _count: true
  });

  return data;
}

export async function getFeaturedProducts() {
  const data = await prisma.product.findMany({
    where: {
      isFeatured: true
    },
    orderBy: {createdAt: 'desc'},
    take: 4

  });

  return convertToPlainObject(data);
}