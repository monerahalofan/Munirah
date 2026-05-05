// ─── Input Sanitization ───────────────────────────────────────────────────────
function sanitize(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
    .trim();
}

// ─── Login Rate Limiter ───────────────────────────────────────────────────────
const RateLimit = {
  KEY:        'mahsoob_login_fails',
  LOCK_KEY:   'mahsoob_login_lock',
  MAX_TRIES:  5,
  LOCK_MS:    15 * 60 * 1000, // 15 minutes

  isLocked() {
    const until = parseInt(localStorage.getItem(this.LOCK_KEY) || '0');
    if (Date.now() < until) return until;
    if (until) { localStorage.removeItem(this.LOCK_KEY); localStorage.removeItem(this.KEY); }
    return false;
  },

  fail() {
    const n = (parseInt(localStorage.getItem(this.KEY) || '0')) + 1;
    localStorage.setItem(this.KEY, n);
    if (n >= this.MAX_TRIES) {
      localStorage.setItem(this.LOCK_KEY, Date.now() + this.LOCK_MS);
    }
    return this.MAX_TRIES - n;
  },

  reset() {
    localStorage.removeItem(this.KEY);
    localStorage.removeItem(this.LOCK_KEY);
  },

  remainingMins(until) {
    return Math.ceil((until - Date.now()) / 60000);
  },
};
