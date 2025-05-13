'use server';

import { signInSchema } from '@/lib/validators';
import { signIn, signOut } from '@/auth';
import { isRedirectError } from 'next/dist/client/components/redirect-error';

export async function signInWithCredentials(prevState: unknown, formData: FormData) {
  try {
    const user = signInSchema.parse({
      email: formData.get('email'),
      password: formData.get('password'),
    });

    await signIn('credentials', user);

    return { success: true, message: 'Successfully logged in' };
  } catch (error) {
    if (isRedirectError(error)) {
      throw error;
    }

    return { success: false, message: 'Incorrect email or password' };
  }
}

export async function signOutUser() {
  await signOut();
}