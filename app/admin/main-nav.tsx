'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import React from 'react';
import { cn } from '@/lib/utils';

const links = [
  {
    title: 'Overview',
    href: '/admin/overview'
  },
  {
    title: 'Products',
    href: '/admin/products'
  },
  {
    title: 'Orders',
    href: '/admin/orders'
  },
  {
    title: 'Users',
    href: '/admin/users'
  },
];

const MainNav = ({ className, ...props }: React.HTMLAttributes<HTMLHtmlElement>) => {
  const pathName = usePathname();

  return (
    <nav className={cn('flex items-center space-x-4 lg:space-x-6',
      className)} {...props}>
      {links.map((item) => (
        <Link href={item.href}
              key={item.href}
              className={cn('text-sm, font-medium transition-colors hover:text-primary',
                pathName.includes(item.href) ? '' : 'text-muted-foreground')}>
          {item.title}
        </Link>
      ))}
    </nav>
  );
};

export default MainNav;