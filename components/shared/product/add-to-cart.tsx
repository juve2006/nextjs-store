'use client';
import { Button } from '@/components/ui/button';
import { useRouter } from 'next/navigation';
import { Plus } from 'lucide-react'
import { CartItem } from '@/types';
import { useToast } from '@/hooks/use-toast';
import { ToastAction} from '@/components/ui/toast';
import { addItemToCart } from '@/lib/actions/cart.actions';

const AddToCart = ({ item }: { item: CartItem }) => {
  const router = useRouter();
  const { toast } = useToast();

  const handleAddToCart = async () => {
    const response = await addItemToCart(item);

    if (!response.success) {
      toast({
        variant: 'destructive',
        description: response.message,
      })
      return;
    }

    toast({
      variant: 'default',
      description: response?.message,
      action: (
        <ToastAction className="bg-gray-600 text-white hover:bg-gray-800" altText="Add to cart" onClick={() => router.push('/cart')}>
          <Plus/> Go To Cart
        </ToastAction>
      )
    })
  };

  return (
     <Button className="w-full" type="button" onClick={handleAddToCart}>Add To Cart </Button>
  );
};

export default AddToCart;