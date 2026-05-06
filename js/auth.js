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
        window.location.href = 'login.html';
        return false;
      }
      this.session = session;
      await this._loadTenant();
      await this._loadProfile();
      this._listenAuthChanges();
      return true;
    } catch(e) {
      console.error('Auth.boot error:', e);
      window.location.href = 'login.html';
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
      if (event === 'SIGNED_OUT') window.location.href = 'login.html';
    });
  },

  async signOut() {
    await _sb.auth.signOut();
    window.location.href = 'login.html';
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
