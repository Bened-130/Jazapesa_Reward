alter table public.profiles
    add column if not exists birth_year smallint;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.profiles'::regclass
          and conname = 'profiles_birth_year_range_check'
    ) then
        alter table public.profiles
            add constraint profiles_birth_year_range_check
            check (birth_year is null or birth_year between 1900 and 2100);
    end if;
end;
$$;

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

revoke all on function public.create_profile_for_new_user() from public, anon, authenticated;

create or replace function public.verify_birth_year(submitted_birth_year integer)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    requesting_user_id uuid := auth.uid();
    existing_birth_year smallint;
begin
    if requesting_user_id is null then
        raise exception 'Authentication required';
    end if;
    if submitted_birth_year is null
        or submitted_birth_year < 1900
        or submitted_birth_year > extract(year from current_date)::integer - 19 then
        raise exception 'Account holders must be at least 18 years old';
    end if;

    update public.profiles
    set birth_year = submitted_birth_year
    where id = requesting_user_id
      and birth_year is null;

    if not found then
        select birth_year into existing_birth_year
        from public.profiles
        where id = requesting_user_id;

        if not found then
            raise exception 'User profile not found';
        end if;
        if existing_birth_year <> submitted_birth_year then
            raise exception 'Birth year has already been verified and cannot be changed';
        end if;
    end if;
end;
$$;

revoke all on function public.verify_birth_year(integer) from public, anon;
grant execute on function public.verify_birth_year(integer) to authenticated;

drop policy if exists "Users can read referrals they sent" on public.referrals;
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

drop policy if exists "Users can read their wallet entries" on public.wallet_entries;
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

drop policy if exists "Users can read their payout requests" on public.payout_requests;
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
    values (requesting_user_id, -requested_amount, 'payout_hold', 'Payout request', request_id);

    return request_id;
end;
$$;

revoke all on function public.request_payout(bigint, text, text) from public, anon;
grant execute on function public.request_payout(bigint, text, text) to authenticated;
