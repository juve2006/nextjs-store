'use client';

import { useRouter, useSearchParams } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { formUrlQuery } from '@/lib/utils';

type PaginationProps = {
  page: number | string;
  total: number;
  urlParamName?: string
};


const Pagination = ({ page, total, urlParamName }: PaginationProps) => {
  const router = useRouter();
  const searchParams = useSearchParams();

  const handleClick = (type: string) => {
    const pageValue = type === 'next' ? Number(page) + 1 : Number(page) - 1;
    const newUrl = formUrlQuery({
      params: searchParams.toString(),
      key: urlParamName || 'page',
      value: pageValue.toString(),
    });

    router.push(newUrl);
  };

  return (
    <>
      <div className="flex gap-2">
        <Button size="lg"
                variant="outline"
                className="w-28"
                disabled={Number(page) <= 1}
                onClick={() => handleClick('prev')}>
          Previous
        </Button>
        <Button size="lg"
                variant="outline"
                className="w-28"
                disabled={Number(page) >= total}
                onClick={() => handleClick('next')}>
          Next
        </Button>
      </div>
    </>
  );
};

export default Pagination;