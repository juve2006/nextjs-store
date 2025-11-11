import { Button } from '@/components/ui/button';
import { SERVER_URL } from '@/lib/constants';
import { formatCurrency } from '@/lib/utils';
import { useState } from 'react';
import { loadStripe } from '@stripe/stripe-js';
import { Elements, useStripe, useElements, PaymentElement, LinkAuthenticationElement } from '@stripe/react-stripe-js';
import { useTheme } from 'next-themes';

type StripePaymentProps = {
  priceInCents: number;
  orderId: string;
  clientSecret: string;
};

const StripePayment = ({ priceInCents, orderId, clientSecret }: StripePaymentProps) => {
  const stripePromise = loadStripe(process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY as string);

  const { theme, systemTheme } = useTheme();

  // Stripe Form Component
  const StripeForm = () => {
    const stripe = useStripe();
    const elements = useElements();

    const [isLoading, setIsLoading] = useState(false);
    const [errorMessage, setErrorMessage] = useState<string>('');
    const [email, setEmail] = useState<string>('');

    const handleSubmit = async (e: FormEvent) => {
      e.preventDefault();

      if (!stripe || !elements || !email) {
        return;
      }

      setIsLoading(true);
      stripe.confirmPayment({
        elements,
        confirmParams: {
          return_url: `${SERVER_URL}/order/${orderId}/stripe-success`,
        },
      }).then(({ error }) => {
        if (error?.type === 'card_error' || error?.type === 'validation_error') {
          setErrorMessage(error?.message || 'An unexpected error occurred.');
        } else if (error) {
          setErrorMessage('An unexpected error occurred.');
        }
      }).finally(() => {
        setIsLoading(false);
      });
    }

    return (
      <form className="space-y-4" onSubmit={handleSubmit}>
        <div className="text-xl">Stripe Checkout</div>
        {errorMessage && <div className="text-destructive">{errorMessage}</div>}
        <PaymentElement />
        <div>
          <LinkAuthenticationElement onChange={(e) => setEmail(e.value.email)}/>
        </div>
        <Button className="w-full" size="lg" disabled={isLoading || !stripe || !elements} >
          {isLoading ? 'Processing...' : `Pay ${formatCurrency(priceInCents / 100)}`}
        </Button>
      </form>
    )
  };

  return (
    <Elements
      options={{
        clientSecret,
        appearance: { theme: theme === 'dark' ? 'night' : 'theme' === 'light' ? 'stripe' : systemTheme === 'light' ? 'stripe' : 'night' },
      }}
      stripe={stripePromise}>
      <StripeForm />
    </Elements>
  );
};

export default StripePayment;