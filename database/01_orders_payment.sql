-- ==============================================================================
-- SCHEMA: ORDERS
-- ==============================================================================
create type orders.status as enum (
    'pending', 'accepted', 'preparing', 'ready', 'picked_up', 'cancelled', 'rejected'
);

create table orders.orders (
    id uuid primary key default uuid_generate_v4(),
    student_id uuid references auth.users(id),
    shop_id uuid references vendors.shops(id),
    status orders.status default 'pending',
    total_amount numeric(10, 2) not null,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

alter table orders.orders enable row level security;

-- Policies
create policy "Students view own orders"
    on orders.orders for select
    using ( auth.uid() = student_id );

create policy "Vendors view shop orders"
    on orders.orders for select
    using ( exists (
        select 1 from vendors.shops s
        where s.id = orders.orders.shop_id
        and s.owner_id = auth.uid()
    ));

create table orders.order_items (
    id uuid primary key default uuid_generate_v4(),
    order_id uuid references orders.orders(id),
    menu_item_id uuid references vendors.menu_items(id),
    quantity int not null,
    price_at_time numeric(10, 2) not null, -- Snapshot of price
    created_at timestamptz default now()
);

alter table orders.order_items enable row level security;

create policy "View items if can view order"
    on orders.order_items for select
    using ( exists (
        select 1 from orders.orders o
        where o.id = orders.order_items.order_id
        and (o.student_id = auth.uid() or exists (
            select 1 from vendors.shops s where s.id = o.shop_id and s.owner_id = auth.uid()
        ))
    ));

-- ==============================================================================
-- SCHEMA: PAYMENTS (Ledger System)
-- ==============================================================================
create table payments.wallets (
    id uuid primary key default uuid_generate_v4(),
    user_id uuid references auth.users(id),
    currency text default 'INR',
    balance numeric(12, 2) default 0.00, -- Cached balance, updated via trigger
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

-- Protect Wallets: No direct updates allowed from API
alter table payments.wallets enable row level security;
create policy "View own wallet"
    on payments.wallets for select
    using ( auth.uid() = user_id );

-- Ledger: The Source of Truth
create table payments.ledger (
    id uuid primary key default uuid_generate_v4(),
    wallet_id uuid references payments.wallets(id),
    amount numeric(12, 2) not null, -- Positive for credit, Negative for debit
    transaction_type text not null, -- 'deposit', 'order_payment', 'refund', 'withdrawal'
    reference_id uuid, -- e.g., order_id
    description text,
    created_at timestamptz default now()
);

alter table payments.ledger enable row level security;

create policy "View own transactions"
    on payments.ledger for select
    using ( exists (
        select 1 from payments.wallets w
        where w.id = payments.ledger.wallet_id
        and w.user_id = auth.uid()
    ));

-- TRIGGER: Update Wallet Balance on Ledger Insert
-- This ensures balance is only modified by appending to the ledger
create or replace function payments.update_wallet_balance()
returns trigger as $$
begin
    update payments.wallets
    set balance = balance + new.amount,
        updated_at = now()
    where id = new.wallet_id;
    return new;
end;
$$ language plpgsql security definer;

create trigger tr_update_balance
after insert on payments.ledger
for each row
execute function payments.update_wallet_balance();

-- Function to handle transfers (e.g., Pay for Order)
-- This encapsulates the logic so client just calls "pay_order"
create or replace function payments.process_payment(
    p_wallet_id uuid, 
    p_amount numeric, 
    p_ref_id uuid, 
    p_desc text
)
returns void as $$
begin
    -- 1. Check balance
    if (select balance from payments.wallets where id = p_wallet_id) < abs(p_amount) and p_amount < 0 then
        raise exception 'Insufficient funds';
    end if;

    -- 2. Insert into ledger (Trigger will update balance)
    insert into payments.ledger (wallet_id, amount, transaction_type, reference_id, description)
    values (p_wallet_id, p_amount, 'order_payment', p_ref_id, p_desc);
end;
$$ language plpgsql security definer;
