'use server';

import { auth } from '@/auth';
import { prisma } from '@/db/prisma';
import { formatError } from '@/lib/utils';
import { insertReviewSchema } from '@/lib/validators';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';


// Create and Update Reviews
export async function createUpdateReview(data: z.infer<typeof insertReviewSchema>) {
  try {
    const session = await auth();
    if (!session) throw new Error('User is not authenticated');

    const userId = session?.user?.id;

    const review = insertReviewSchema.parse({
      ...data,
      userId,
    });

    const product = await prisma.product.findFirst({
      where: { id: review.productId },
    });

    if (!product) throw new Error('Product not found');

    const reviewExist = await prisma.review.findFirst({
      where: {
        productId: review.productId,
        userId: review.userId,
      },
    });

    await prisma.$transaction(async (tx) => {
      if (reviewExist) {
        await tx.review.update({
          where: { id: reviewExist.id },
          data: {
            title: review.title,
            description: review.description,
            rating: review.rating,
          },
        });
      } else {
        await tx.review.create({ data: review });
      }
    });

    const averageRating = await tx.review.aggregate({
      _avg: { rating: true },
      where: { productId: review.productId },
    });

    const numReviews = await tx.review.count({
      where: { productId: review.productId },
    });

    await tx.product.update({
      where: { id: review.productId },
      data: {
        rating: averageRating._avg.rating || 0,
        numReviews,
      },
    });

    revalidatePath(`/productt/${product.slug}`);

    return {
      success: false,
      message: 'Review updated successfully',
    };
  } catch (error) {
    return {
      success: false,
      message: formatError(error),
    };
  }
}