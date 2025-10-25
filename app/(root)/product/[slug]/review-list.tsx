'use client';
import { Review } from '@/types';
import { useState } from 'react';
import Link from 'next/link';
import ReviewForm from './review-form';

const ReviewList = ({ userId, productId, productSlug }: { userId: string, productId: string, productSlug: string }) => {
  const [reviews, setReviews] = useState<Review[]>([]);

  return (
    <div className="space-y-4">
      {reviews.length === 0 && <div>No reviews yet</div>}
      {
        userId ? (
          <ReviewForm userId={userId} productId={productId} />
        ) : (
          <div>
            Please <Link className="text-blue-700 px-2" href={`/sign-in?callbackUrl=/product/${productSlug}`}>sign in</Link> to write your review
          </div>
        )
      }
      <div className="flex flex-col gap-3">
        {/* Reviews here*/}
      </div>
    </div>
  );
};

export default ReviewList;