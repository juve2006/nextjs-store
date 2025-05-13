'use client';

import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { Input } from '@/components/ui/input';
import { signInDefaultValues } from '@/lib/constants';
import Link from 'next/link';

const CredentialSignInForm = () => {
  return (
    <form>
      <div className="space-y-6">
        <div>
          <Label htmlFor="email">Email</Label>
          <Input id="email"
                 name="email"
                 type="email"
                 required={true}
                 autoComplete={'email'}
                 autoFocus={true}
                 defaultValue={signInDefaultValues.email}/>
        </div>
        <div>
          <Label htmlFor="password">Password</Label>
          <Input id="password"
                 name="password"
                 type="password"
                 required={true}
                 autoComplete={'password'}
                 autoFocus={true}
                 defaultValue={signInDefaultValues.password}/>
        </div>
        <div>
          <Button type="submit" className="w-full mb-2" variant="default">Sign In</Button>
          <div className="text-sm text-center text-muted-foreground">
            Don&apos;t have an account? {'  '}
            <Link href="/sign-up"
                  target="_self"
                  className="link">
              Sign Up
            </Link>
          </div>
        </div>
      </div>
    </form>
  );
};

export default CredentialSignInForm;