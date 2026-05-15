// ─── Auth & Session Management ────────────────────────────────────────────

const _sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const Auth = {
  // Current session state
  session: null,
  tenant: null,
  profile: null,

  // Boot: called once on app load — redirects to login if no session
  async boot() {
    try {
      const { data: { session }, error } = await _sb.auth.getSession();
      if (error || !session) {
        window.location.href = '/login';
        return false;
      }
      this.session = session;
      await this._loadTenant();
      await this._loadProfile();
      this._listenAuthChanges();
      return true;
    } catch(e) {
      console.error('Auth.boot error:', e);
      window.location.href = '/login';
      return false;
    }
  },

  // Load the tenant (business) associated with this user
  async _loadTenant() {
    const { data } = await _sb
      .from('tenants')
      .select('*')
      .eq('owner_id', this.session.user.id)
      .maybeSingle();

    if (!data) {
      // First login — create tenant from signup metadata
      const meta = this.session.user.user_metadata || {};
      const { data: newTenant } = await _sb.from('tenants').insert({
        owner_id:   this.session.user.id,
        name:       meta.business_name || meta.full_name || 'مشروعي',
        plan:       'free',
        vat_number: meta.vat_number  || null,
        cr_number:  meta.cr_number   || null,
        city:       meta.city        || 'الرياض',
        address:    meta.address     || null,
      }).select().single();
      this.tenant = newTenant;
    } else {
      this.tenant = data;
    }
  },

  // Load user profile (role inside this tenant)
  async _loadProfile() {
    const { data } = await _sb
      .from('tenant_users')
      .select('*')
      .eq('user_id', this.session.user.id)
      .eq('tenant_id', this.tenant.id)
      .maybeSingle();

    if (!data) {
      // Owner — insert as admin
      const { data: p } = await _sb.from('tenant_users').insert({
        user_id: this.session.user.id,
        tenant_id: this.tenant.id,
        role: 'admin',
        display_name: this.session.user.user_metadata?.business_name || 'المدير',
      }).select().single();
      this.profile = p;
    } else {
      this.profile = data;
    }
  },

  _listenAuthChanges() {
    _sb.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT') window.location.href = '/login';
    });
  },

  async signOut() {
    await _sb.auth.signOut();
    window.location.href = '/login';
  },

  // Returns true if current plan allows a feature
  can(feature) {
    const plan = PLANS[this.tenant?.plan || 'free'];
    return !!plan?.[feature];
  },

  planName() {
    return PLANS[this.tenant?.plan || 'free']?.name || 'تجريبي';
  },
};

// ─── DB helpers — all queries are tenant-scoped ───────────────────────────
const DB = {
  // Transactions
  async getTransactions() {
    const { data } = await _sb
      .from('transactions')
      .select('*')
      .eq('tenant_id', Auth.tenant.id)
      .order('date', { ascending: false });
    return data || [];
  },

  async addTransaction(tx) {
    const { data, error } = await _sb.from('transactions').insert({
      ...tx,
      tenant_id: Auth.tenant.id,
      created_by: Auth.session.user.id,
    }).select().single();
    if (error) throw error;
    // Auto-post journal entries
    await Journal.postFromTransaction(data).catch(e => console.warn('JE post failed', e));
    return data;
  },

  async deleteTransaction(id) {
    await _sb.from('transactions').delete()
      .eq('id', id).eq('tenant_id', Auth.tenant.id);
  },

  // Invoices
  async getInvoices() {
    const { data } = await _sb
      .from('invoices')
      .select('*')
      .eq('tenant_id', Auth.tenant.id)
      .order('created_at', { ascending: false });
    return data || [];
  },

  async addInvoice(inv) {
    const { data, error } = await _sb.from('invoices').insert({
      ...inv,
      tenant_id: Auth.tenant.id,
      created_by: Auth.session.user.id,
    }).select().single();
    if (error) throw error;
    // Auto-post journal entries
    await Journal.postFromInvoice(data).catch(e => console.warn('JE post failed', e));
    return data;
  },

  async updateInvoice(id, updates) {
    await _sb.from('invoices').update(updates)
      .eq('id', id).eq('tenant_id', Auth.tenant.id);
  },

  // Budget categories
  async getBudget() {
    const { data } = await _sb
      .from('budget_categories')
      .select('*')
      .eq('tenant_id', Auth.tenant.id)
      .order('name');
    return data || [];
  },

  async upsertBudgetCategory(cat) {
    const { data } = await _sb.from('budget_categories').upsert({
      ...cat,
      tenant_id: Auth.tenant.id,
    }).select().single();
    return data;
  },

  // Goals
  async getGoals() {
    const { data } = await _sb
      .from('goals')
      .select('*')
      .eq('tenant_id', Auth.tenant.id)
      .order('created_at');
    return data || [];
  },

  async upsertGoal(goal) {
    const { data } = await _sb.from('goals').upsert({
      ...goal,
      tenant_id: Auth.tenant.id,
    }).select().single();
    return data;
  },

  // Scan log (track AI invoice scans against plan limit)
  async getScanCount() {
    const start = new Date();
    start.setDate(1); start.setHours(0,0,0,0);
    const { count } = await _sb
      .from('scan_log')
      .select('*', { count: 'exact', head: true })
      .eq('tenant_id', Auth.tenant.id)
      .gte('created_at', start.toISOString());
    return count || 0;
  },

  async logScan() {
    await _sb.from('scan_log').insert({
      tenant_id: Auth.tenant.id,
      user_id: Auth.session.user.id,
    });
  },

  // Tenant users
  async getUsers() {
    const { data } = await _sb
      .from('tenant_users')
      .select('*')
      .eq('tenant_id', Auth.tenant.id);
    return data || [];
  },
};

// ═══════════════════════════════════════════════════════════════════════
// Journal — Double-entry bookkeeping service
// ═══════════════════════════════════════════════════════════════════════
const Journal = {

  // Post a balanced journal entry (multiple lines, debit total = credit total)
  async post(lines, opts = {}) {
    if (!Array.isArray(lines) || lines.length < 2)
      throw new Error('Journal entry needs at least 2 lines');

    const debit  = lines.reduce((s, l) => s + (parseFloat(l.debit)  || 0), 0);
    const credit = lines.reduce((s, l) => s + (parseFloat(l.credit) || 0), 0);
    if (Math.abs(debit - credit) > 0.001)
      throw new Error(`Unbalanced entry: DR=${debit} CR=${credit}`);

    const rows = lines.map(l => ({
      tenant_id:    Auth.tenant.id,
      account_code: l.account_code,
      entry_date:   opts.date || new Date().toISOString().slice(0, 10),
      debit:        parseFloat(l.debit)  || 0,
      credit:       parseFloat(l.credit) || 0,
      description:  l.description || opts.description || '',
      ref_type:     opts.ref_type || 'manual',
      ref_id:       opts.ref_id  || null,
      cost_center:  l.cost_center || opts.cost_center || null,
      created_by:   Auth.session.user.id,
    }));

    const { data, error } = await _sb.from('journal_entries').insert(rows).select();
    if (error) throw error;
    return data;
  },

  // Auto-post from a transaction (income/expense)
  async postFromTransaction(tx) {
    const isIncome = tx.type === 'income';
    const amount   = parseFloat(tx.amount);
    if (!amount || amount <= 0) return null;

    // Income (cash):  DR 1101 Cash      CR 4101 Sales Revenue
    // Expense (cash): DR 6107 Expense   CR 1101 Cash
    const cashAccount = '1101';                  // الصندوق
    const incomeAcct  = '4101';                  // إيرادات المبيعات
    const expenseAcct = tx.category_account || '6107'; // مصاريف أخرى افتراضي

    let lines;
    if (isIncome) {
      lines = [
        { account_code: cashAccount, debit:  amount, credit: 0 },
        { account_code: incomeAcct,  debit:  0,      credit: amount },
      ];
    } else {
      lines = [
        { account_code: expenseAcct, debit:  amount, credit: 0 },
        { account_code: cashAccount, debit:  0,      credit: amount },
      ];
    }
    return this.post(lines, {
      ref_type:    'transaction',
      ref_id:      tx.id,
      date:        tx.date || tx.created_at?.slice(0,10),
      description: tx.party ? `${tx.category || ''} — ${tx.party}` : (tx.category || ''),
    });
  },

  // Auto-post from an invoice
  async postFromInvoice(inv) {
    const total    = parseFloat(inv.total || inv.amount || 0);
    const vat      = parseFloat(inv.vat   || 0);
    const subtotal = total - vat;
    if (total <= 0) return null;

    // Sales Invoice:
    //   DR 1103 Receivables       (total inc. VAT)
    //   CR 4101 Sales Revenue     (subtotal)
    //   CR 2103 VAT Output        (vat) — if exists
    const lines = [
      { account_code: '1103', debit:  total,    credit: 0 },
      { account_code: '4101', debit:  0,        credit: subtotal },
    ];
    if (vat > 0) {
      lines.push({ account_code: '2103', debit: 0, credit: vat });
    }
    return this.post(lines, {
      ref_type:    'invoice',
      ref_id:      inv.id,
      date:        inv.invoice_date || inv.created_at?.slice(0,10),
      description: `فاتورة ${inv.invoice_number || ''} — ${inv.client_name || ''}`.trim(),
    });
  },

  // Fetch ledger entries for a specific account
  async getLedger(accountCode, opts = {}) {
    let q = _sb.from('journal_entries')
      .select('*')
      .eq('tenant_id', Auth.tenant.id)
      .eq('account_code', accountCode)
      .order('entry_date', { ascending: true });
    if (opts.from) q = q.gte('entry_date', opts.from);
    if (opts.to)   q = q.lte('entry_date', opts.to);
    const { data, error } = await q;
    if (error) throw error;
    return data || [];
  },

  // Fetch current balance for an account
  async getBalance(accountCode) {
    const { data } = await _sb.from('account_balances')
      .select('*')
      .eq('tenant_id', Auth.tenant.id)
      .eq('account_code', accountCode)
      .maybeSingle();
    return data || { total_debit: 0, total_credit: 0, balance: 0 };
  },
};
