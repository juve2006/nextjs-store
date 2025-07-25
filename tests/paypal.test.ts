import { generateAccessToken, paypal } from '../lib/paypal';

test('generates token from paypal',
  async () => {
    const tokenResponse = await generateAccessToken();

    expect(typeof tokenResponse).toBe('string');
    expect(tokenResponse.length).toBeGreaterThan(0);
  },
);

test('creates a paypal order',
  async () => {
    const token = await generateAccessToken();
    const price = 10.0;

    const orderResponse = await paypal.createOrder(price);

    expect(orderResponse).toHaveProperty('id');
    expect(orderResponse).toHaveProperty('status');
    expect(orderResponse.status).toBe('CREATED');
  },
);

test('simulate capturing a payment from order',
  async () => {
    const orderId = '11111';

    const mockCapturePayment = jest
      .spyOn(paypal, 'capturePayment')
      .mockResolvedValue({ status: 'COMPLETED' });

    const captureResponse = await paypal.capturePayment(orderId);
    expect(captureResponse).toHaveProperty('status', 'COMPLETED');

    mockCapturePayment.mockRestore();
  },
);