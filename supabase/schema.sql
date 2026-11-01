create table public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    display_name text not null default '',
    phone text not null default '',
    birth_year smallint not null check (birth_year between 1900 and 2100),
    referral_code text not null unique,
    referred_by uuid references public.profiles (id) on delete set null,
    created_at timestamptz not null default now()
);

create table public.referrals (
    id uuid primary key default gen_random_uuid(),
    referrer_id uuid not null references public.profiles (id) on delete cascade,
    referred_id uuid not null unique references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now(),
    constraint referrals_no_self_referral check (referrer_id <> referred_id)
);

create table public.wallet_entries (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles (id) on delete cascade,
    amount bigint not null check (amount <> 0),
    entry_type text not null,
    description text not null default '',
    payout_request_id uuid,
    created_at timestamptz not null default now(),
    constraint wallet_entries_payout_request_entry_unique unique (payout_request_id, entry_type)
);

create table public.payout_requests (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles (id) on delete cascade,
    amount bigint not null check (amount > 0),
    method text not null check (method in ('mpesa', 'bank')),
    destination text not null check (length(trim(destination)) between 4 and 200),
    status text not null default 'pending'
        check (status in ('pending', 'processing', 'paid', 'rejected')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.wallet_entries
    add constraint wallet_entries_payout_request_fk
    foreign key (payout_request_id)
    references public.payout_requests (id)
    on delete restrict;

create index referrals_referrer_id_idx on public.referrals (referrer_id);
create index wallet_entries_user_created_idx on public.wallet_entries (user_id, created_at desc);
create index payout_requests_user_created_idx on public.payout_requests (user_id, created_at desc);

alter table public.profiles enable row level security;
alter table public.referrals enable row level security;
alter table public.wallet_entries enable row level security;
alter table public.payout_requests enable row level security;

create policy "Users can read their profile"
    on public.profiles for select to authenticated
    using (id = (select auth.uid()));

create policy "Users can update their profile details"
    on public.profiles for update to authenticated
    using (id = (select auth.uid()))
    with check (id = (select auth.uid()));

create policy "Users can read referrals they sent"
    on public.referrals for select to authenticated
    using (
        referrer_id = (select auth.uid())
        and exists (
            select 1 from public.profiles p
            where p.id = (select auth.uid())
              and p.birth_year <= extract(year from current_date)::integer - 19
        )
    );

create policy "Users can read their wallet entries"
    on public.wallet_entries for select to authenticated
    using (
        user_id = (select auth.uid())
        and exists (
            select 1 from public.profiles p
            where p.id = (select auth.uid())
              and p.birth_year <= extract(year from current_date)::integer - 19
        )
    );

create policy "Users can read their payout requests"
    on public.payout_requests for select to authenticated
    using (
        user_id = (select auth.uid())
        and exists (
            select 1 from public.profiles p
            where p.id = (select auth.uid())
              and p.birth_year <= extract(year from current_date)::integer - 19
        )
    );

grant usage on schema public to authenticated;
grant select on public.profiles, public.referrals, public.wallet_entries, public.payout_requests to authenticated;
grant update (display_name, phone) on public.profiles to authenticated;
grant usage on schema public to service_role;
grant all on public.profiles, public.referrals, public.wallet_entries, public.payout_requests to service_role;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    new_referral_code text;
    referrer_profile_id uuid;
    supplied_referral_code text;
    supplied_birth_year text;
    parsed_birth_year integer;
begin
    supplied_birth_year := coalesce(new.raw_user_meta_data ->> 'birth_year', '');

    if supplied_birth_year !~ '^[0-9]{4}$' then
        raise exception 'A valid four-digit birth year is required';
    end if;

    parsed_birth_year := supplied_birth_year::integer;
    if parsed_birth_year < 1900
        or parsed_birth_year > extract(year from current_date)::integer - 19 then
        raise exception 'Account holders must be at least 18 years old';
    end if;

    loop
        new_referral_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
        exit when not exists (
            select 1 from public.profiles where referral_code = new_referral_code
        );
    end loop;

    supplied_referral_code := upper(trim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));

    select id into referrer_profile_id
    from public.profiles
    where referral_code = supplied_referral_code
      and id <> new.id;

    insert into public.profiles (id, display_name, phone, birth_year, referral_code, referred_by)
    values (
        new.id,
        coalesce(new.raw_user_meta_data ->> 'display_name', ''),
        coalesce(new.raw_user_meta_data ->> 'phone', ''),
        parsed_birth_year,
        new_referral_code,
        referrer_profile_id
    );

    if referrer_profile_id is not null then
        insert into public.referrals (referrer_id, referred_id)
        values (referrer_profile_id, new.id);
    end if;

    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.create_profile_for_new_user();

revoke all on function public.create_profile_for_new_user() from public, anon, authenticated;

create or replace function public.wallet_balance()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    requesting_user_id uuid := auth.uid();
    result_balance bigint;
begin
    if requesting_user_id is null then
        raise exception 'Authentication required';
    end if;

    if not exists (
        select 1 from public.profiles
        where id = requesting_user_id
          and birth_year <= extract(year from current_date)::integer - 19
    ) then
        raise exception 'Age verification is required to access the wallet';
    end if;

    select coalesce(sum(amount), 0)::bigint into result_balance
    from public.wallet_entries
    where user_id = requesting_user_id;

    return result_balance;
end;
$$;

revoke all on function public.wallet_balance() from public, anon;
grant execute on function public.wallet_balance() to authenticated;

create or replace function public.request_payout(
    requested_amount bigint,
    payout_method text,
    payout_destination text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    requesting_user_id uuid := auth.uid();
    available_balance bigint;
    request_id uuid;
    verified_birth_year smallint;
begin
    if requesting_user_id is null then
        raise exception 'Authentication required';
    end if;
    if requested_amount is null or requested_amount <= 0 then
        raise exception 'Payout amount must be greater than zero';
    end if;
    if payout_method not in ('mpesa', 'bank') then
        raise exception 'Unsupported payout method';
    end if;
    if payout_destination is null or length(trim(payout_destination)) not between 4 and 200 then
        raise exception 'A valid payout destination is required';
    end if;

    select birth_year into verified_birth_year
    from public.profiles
    where id = requesting_user_id
    for update;
    if not found then
        raise exception 'User profile not found';
    end if;
    if verified_birth_year is null
        or verified_birth_year > extract(year from current_date)::integer - 19 then
        raise exception 'Age verification is required before requesting a payout';
    end if;

    select coalesce(sum(amount), 0)::bigint into available_balance
    from public.wallet_entries
    where user_id = requesting_user_id;

    if requested_amount > available_balance then
        raise exception 'Payout amount exceeds available balance';
    end if;

    insert into public.payout_requests (user_id, amount, method, destination)
    values (requesting_user_id, requested_amount, payout_method, trim(payout_destination))
    returning id into request_id;

    insert into public.wallet_entries (user_id, amount, entry_type, description, payout_request_id)
    values (
        requesting_user_id,
        -requested_amount,
        'payout_hold',
        'Payout request',
        request_id
    );

    return request_id;
end;
$$;

revoke all on function public.request_payout(bigint, text, text) from public, anon;
grant execute on function public.request_payout(bigint, text, text) to authenticated;

create or replace function public.refund_rejected_payout()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if old.status in ('paid', 'rejected') and new.status <> old.status then
        raise exception 'A completed payout request cannot be reopened';
    end if;

    if new.status = 'rejected' and old.status <> 'rejected' then
        insert into public.wallet_entries (user_id, amount, entry_type, description, payout_request_id)
        values (
            new.user_id,
            new.amount,
            'payout_return',
            'Rejected payout returned to balance',
            new.id
        )
        on conflict (payout_request_id, entry_type) do nothing;
    end if;

    new.updated_at := now();
    return new;
end;
$$;

create trigger on_payout_status_changed
    before update of status on public.payout_requests
    for each row execute function public.refund_rejected_payout();

revoke all on function public.refund_rejected_payout() from public, anon, authenticated;
