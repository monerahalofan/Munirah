// ─── Supabase Configuration ───────────────────────────────────────────────
// Replace these values with your actual Supabase project credentials.
// Get them from: https://supabase.com/dashboard → Project Settings → API

const SUPABASE_URL  = 'https://icmpdgayzwwgbaqqcfnr.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImljbXBkZ2F5end3Z2JhcXFjZm5yIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY5OTgyODAsImV4cCI6MjA5MjU3NDI4MH0.mbXOMCHLlzbvmqdTxdNW08At-leZIOj1MRWESBIZu-I';

// ─── Subscription Plans ───────────────────────────────────────────────────
const PLANS = {
  free:     { name: 'تجريبي',    scan_limit: 5,   users: 1, ai: false },
  starter:  { name: 'مبتدئ',     scan_limit: 50,  users: 1, ai: false },
  pro:      { name: 'احترافي',   scan_limit: 999, users: 5, ai: true  },
  business: { name: 'أعمال',     scan_limit: 999, users: 999, ai: true },
};

// ─── App Version ──────────────────────────────────────────────────────────
const APP_VERSION = '4.0.0';
