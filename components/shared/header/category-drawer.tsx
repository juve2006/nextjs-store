import { getAllCategories } from '@/lib/actions/product.actions';
import { Drawer, DrawerClose, DrawerContent, DrawerHeader, DrawerTitle, DrawerTrigger } from '@/components/ui/drawer';
import { Button } from '@/components/ui/button';
import { MenuIcon } from 'lucide-react'
import Link from 'next/link';

const CategoryDrawer = async () => {
  const categories = await getAllCategories();

  return (
    <Drawer direction="left">
      <DrawerTrigger asChild>
        <Button variant="outline">
          <MenuIcon/>
        </Button>
      </DrawerTrigger>
      <DrawerContent className="h-full max-w-sm">
        <DrawerHeader>
          <DrawerTitle> Select a category</DrawerTitle>
          <div className="space-y-1 mt-4">
            {categories.map((item) => (
              <Button key={item.category} asChild variant="ghost" className="w-full justify-start">
                <DrawerClose asChild>
                  <Link href={`/search?category=${item.category}`}>
                    {item.category} ({item._count})
                  </Link>
                </DrawerClose>
              </Button>
            ))}
          </div>
        </DrawerHeader>
      </DrawerContent>
    </Drawer>
  );
};

export default CategoryDrawer;