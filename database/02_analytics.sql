-- ==============================================================================
-- SCHEMA: ANALYTICS
-- ==============================================================================

-- 1. Vendor Daily Revenue View
create or replace view analytics.vendor_daily_revenue as
select 
    s.id as shop_id,
    s.name as shop_name,
    date_trunc('day', o.created_at) as day,
    count(o.id) as total_orders,
    sum(o.total_amount) as total_revenue
from orders.orders o
join vendors.shops s on o.shop_id = s.id
where o.status = 'picked_up' -- Only count completed orders
group by s.id, s.name, date_trunc('day', o.created_at);

-- Security: Vendors only see their own
alter view analytics.vendor_daily_revenue owner to postgres; -- Ensure owner has rights
-- Note: Views in Supabase/Postgres don't support RLS directly unless `security_invoker` is used or we wrap in a function.
-- Let's use a secure function to wrap this for API access, or rely on RLS on underlying tables if view uses `security_invoker`.

-- Better approach for RLS on Views: Use `security_invoker = true`
-- This enforces RLS of the underlying tables (orders, shops) on the user querying the view.
alter view analytics.vendor_daily_revenue set (security_invoker = true);


-- 2. Admin Campus Stats View
create or replace view analytics.campus_stats as
select 
    count(o.id) as total_life_orders,
    sum(o.total_amount) as total_life_volume,
    (select count(*) from auth.users) as total_users,
    (select count(*) from vendors.shops where is_open = true) as active_shops
from orders.orders o
where o.status = 'picked_up';

alter view analytics.campus_stats set (security_invoker = true);

-- Since underlying tables are protected, we need to ensure Admins can actually see ALL data.
-- Standard RLS on `orders` prevents students/vendors from seeing global stats.
-- We might need a `security definer` function for this specific Admin dashboard if they need global stats that they wouldn't normally have access to via simple RLS (though Admins usually have broad RLS).

-- Example Admin Function
create or replace function analytics.get_admin_stats()
returns jsonb
language plpgsql
security definer -- Runs as creator (ensure creator is superuser/admin)
as $$
declare
    result jsonb;
begin
    -- Check permissions
    if core.get_user_role(auth.uid()) not in ('admin', 'super_admin') then
        raise exception 'Access Denied';
    end if;

    select jsonb_build_object(
        'total_orders', count(*),
        'total_volume', sum(total_amount)
    ) into result
    from orders.orders;
    
    return result;
end;
$$;
