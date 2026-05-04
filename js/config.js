// ─── Supabase Configuration ───────────────────────────────────────────────
// Replace these values with your actual Supabase project credentials.
// Get them from: https://supabase.com/dashboard → Project Settings → API

const SUPABASE_URL  = 'https://rkyusvgozmsrftpxzjhb.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJreXVzdmdvem1zcmZ0cHh6amhiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1NzY0NjMsImV4cCI6MjA5MzE1MjQ2M30.sgPNR3_ucYUEA9hdamMSjs-MTpjoxsQFz1fHkWedJkE';

// ─── Subscription Plans ───────────────────────────────────────────────────
const PLANS = {
  free:     { name: 'تجريبي',    scan_limit: 5,   users: 1, ai: false },
  starter:  { name: 'مبتدئ',     scan_limit: 50,  users: 1, ai: false },
  pro:      { name: 'احترافي',   scan_limit: 999, users: 5, ai: true  },
  business: { name: 'أعمال',     scan_limit: 999, users: 999, ai: true },
};

// ─── App Version ──────────────────────────────────────────────────────────
const APP_VERSION = '4.0.0';
