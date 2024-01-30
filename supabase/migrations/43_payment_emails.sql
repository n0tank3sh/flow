begin;

create or replace view internal.free_trial_tenants as
select
  'free_trial' as alert_type,
  (tenants.tenant || 'alerts/free_trial')::catalog_name as catalog_name,
  alert_subscriptions.email,
  auth.users.raw_user_meta_data->>'full_name' as full_name,
  tenants.tenant,
  tenants.trial_start::date,
  (tenants.trial_start + interval '1 month')::date as trial_end,
  stripe.customers."invoice_settings/default_payment_method" is not null as has_credit_card
from tenants
  left join alert_subscriptions on alert_subscriptions.catalog_prefix ^@ tenants.tenant and email is not null
  left join stripe.customers on stripe.customers."name" = tenants.tenant
  -- Filter out sso users because auth.users is only guarinteed unique when that is false:
  -- CREATE UNIQUE INDEX users_email_partial_key ON auth.users(email text_ops) WHERE is_sso_user = false;
  left join auth.users on auth.users.email = alert_subscriptions.email and auth.users.is_sso_user is false
where tenants.trial_start is not null and
  -- Select for tenants currently in their free trials
  -- meaning trial start is at most 1 month ago
  (now() - tenants.trial_start) < interval '1 month' and
  -- Filter out unexpected future start dates
  tenants.trial_start <= now()
group by
    tenants.tenant,
    tenants.trial_start,
    alert_subscriptions.email,
    customers.name,
    users.raw_user_meta_data,
    stripe.customers."invoice_settings/default_payment_method";

-- Trigger 5 days before trial ends
create or replace view internal.free_trial_ending_tenants as
select
  'free_trial_ending' as alert_type,
  (tenants.tenant || 'alerts/free_trial_ending')::catalog_name as catalog_name,
  alert_subscriptions.email,
  auth.users.raw_user_meta_data->>'full_name' as full_name,
  tenants.tenant,
  tenants.trial_start::date,
  (tenants.trial_start + interval '1 month')::date as trial_end,
  stripe.customers."name" is null as has_credit_card
from tenants
  left join alert_subscriptions on alert_subscriptions.catalog_prefix ^@ tenants.tenant and email is not null
  left join stripe.customers on stripe.customers."name" = tenants.tenant
  -- Filter out sso users because auth.users is only guarinteed unique when that is false:
  -- CREATE UNIQUE INDEX users_email_partial_key ON auth.users(email text_ops) WHERE is_sso_user = false;
  left join auth.users on auth.users.email = alert_subscriptions.email and auth.users.is_sso_user is false
where tenants.trial_start is not null and
  (now() - tenants.trial_start) >= (interval '1 month' - interval '5 days') and
  (now() - tenants.trial_start) < (interval '1 month' - interval '4 days') and
  -- Filter out unexpected future start dates
  tenants.trial_start <= now()
group by
    tenants.tenant,
    tenants.trial_start,
    alert_subscriptions.email,
    customers.name,
    users.raw_user_meta_data;

-- Alert us internally when they go past 5 days over the trial
create or replace view internal.delinquent_tenants as
select
  'delinquent_tenant' as alert_type,
  (tenants.tenant || 'alerts/delinquent_tenant')::catalog_name as catalog_name,
  alert_subscriptions.email,
  auth.users.raw_user_meta_data->>'full_name' as full_name,
  tenants.tenant,
  tenants.trial_start::date,
  (tenants.trial_start + interval '1 month')::date as trial_end
from tenants
  left join alert_subscriptions on alert_subscriptions.catalog_prefix ^@ tenants.tenant and email is not null
  left join stripe.customers on stripe.customers."name" = tenants.tenant
  -- Filter out sso users because auth.users is only guarinteed unique when that is false:
  -- CREATE UNIQUE INDEX users_email_partial_key ON auth.users(email text_ops) WHERE is_sso_user = false;
  left join auth.users on auth.users.email = alert_subscriptions.email and auth.users.is_sso_user is false
where tenants.trial_start is not null and
  (now() - tenants.trial_start) >= interval '1 month' + interval '5 days' and
    -- Filter out unexpected future start dates
  tenants.trial_start <= now() and
  stripe.customers."invoice_settings/default_payment_method" is null
group by
    tenants.tenant,
    tenants.trial_start,
    alert_subscriptions.email,
    customers.name,
    users.raw_user_meta_data;

create or replace view internal.paid_tenants as
select
  'paid_tenant' as alert_type,
  (tenants.tenant || 'alerts/paid_tenant')::catalog_name as catalog_name,
  alert_subscriptions.email,
  auth.users.raw_user_meta_data->>'full_name' as full_name,
  tenants.tenant,
  tenants.trial_start::date,
  (tenants.trial_start + interval '1 month')::date as trial_end,
  -- if tenants.trial_start is null, that means they entered their cc
  -- while they're still in the free tier
  coalesce((now() - tenants.trial_start) < interval '1 month', false) as in_trial,
  tenants.trial_start is null as straight_from_free_tier
from tenants
  left join alert_subscriptions on alert_subscriptions.catalog_prefix ^@ tenants.tenant and email is not null
  left join stripe.customers on stripe.customers."name" = tenants.tenant
  -- Filter out sso users because auth.users is only guarinteed unique when that is false:
  -- CREATE UNIQUE INDEX users_email_partial_key ON auth.users(email text_ops) WHERE is_sso_user = false;
  left join auth.users on auth.users.email = alert_subscriptions.email and auth.users.is_sso_user is false
where stripe.customers."invoice_settings/default_payment_method" is not null
group by
    tenants.tenant,
    tenants.trial_start,
    alert_subscriptions.email,
    customers.name,
    users.raw_user_meta_data;

-- Have to update this to join in auth.users for full_name support
-- Update to v2 because of the change from `emails` to `recipients`
create or replace view internal.alert_data_processing_firing_v2 as
select
  alert_data_processing.*,
  'data_not_processed_in_interval_v2' as alert_type,
  alert_subscriptions.email,
  auth.users.raw_user_meta_data->>'full_name' as full_name,
  live_specs.spec_type,
  coalesce(sum(catalog_stats_hourly.bytes_written_by_me + catalog_stats_hourly.bytes_written_to_me + catalog_stats_hourly.bytes_read_by_me), 0)::bigint as bytes_processed
from alert_data_processing
  left join live_specs on alert_data_processing.catalog_name = live_specs.catalog_name and live_specs.spec is not null and (live_specs.spec->'shards'->>'disable')::boolean is not true
  left join catalog_stats_hourly on alert_data_processing.catalog_name = catalog_stats_hourly.catalog_name and catalog_stats_hourly.ts >= date_trunc('hour', now() - alert_data_processing.evaluation_interval)
  left join alert_subscriptions on alert_data_processing.catalog_name ^@ alert_subscriptions.catalog_prefix and email is not null
  -- Filter out sso users because auth.users is only guarinteed unique when that is false:
  -- CREATE UNIQUE INDEX users_email_partial_key ON auth.users(email text_ops) WHERE is_sso_user = false;
  left join auth.users on auth.users.email = alert_subscriptions.email and auth.users.is_sso_user is false
where live_specs.created_at <= date_trunc('hour', now() - alert_data_processing.evaluation_interval)
group by
  alert_data_processing.catalog_name,
  alert_data_processing.evaluation_interval,
  alert_subscriptions.email,
  live_specs.spec_type,
  users.raw_user_meta_data
having coalesce(sum(catalog_stats_hourly.bytes_written_by_me + catalog_stats_hourly.bytes_written_to_me + catalog_stats_hourly.bytes_read_by_me), 0)::bigint = 0;

create or replace view alert_all_firing as
with data_processing as (
  select
    catalog_name,
    alert_type,
    json_build_object(
      'bytes_processed', bytes_processed,
      'recipients', array_agg(json_build_object(
        'email', email,
        'full_name', full_name
      )),
      'evaluation_interval', evaluation_interval,
      'spec_type', spec_type
      ) as arguments
  from internal.alert_data_processing_firing_v2
  group by
    catalog_name,
    alert_type,
    bytes_processed,
    evaluation_interval,
    spec_type
),
free_trial as (
  select
    catalog_name,
    alert_type,
    json_build_object(
      'tenant', tenant,
      'recipients', array_agg(json_build_object(
        'email', email,
        'full_name', full_name
      )),
      'trial_start', trial_start,
      'trial_end', trial_end,
      'has_credit_card', has_credit_card
      ) as arguments
  from internal.free_trial_tenants
  group by
    catalog_name,
    tenant,
    alert_type,
    trial_start,
    trial_end,
    has_credit_card
),
free_trial_ending as (
  select
    catalog_name,
    alert_type,
    json_build_object(
      'tenant', tenant,
      'recipients', array_agg(json_build_object(
        'email', email,
        'full_name', full_name
      )),
      'trial_start', trial_start,
      'trial_end', trial_end,
      'has_credit_card', has_credit_card
      ) as arguments
  from internal.free_trial_ending_tenants
  group by
    catalog_name,
    tenant,
    alert_type,
    trial_start,
    trial_end,
    has_credit_card
),
delinquent_tenants as (
  select
    catalog_name,
    alert_type,
    json_build_object(
      'tenant', tenant,
      'recipients', array_agg(json_build_object(
        'email', email,
        'full_name', full_name
      )),
      'trial_start', trial_start,
      'trial_end', trial_end
      ) as arguments
  from internal.delinquent_tenants
  group by
    catalog_name,
    tenant,
    alert_type,
    trial_start,
    trial_end
),
paid_tenants as (
  select
    catalog_name,
    alert_type,
    json_build_object(
      'tenant', tenant,
      'recipients', array_agg(json_build_object(
        'email', email,
        'full_name', full_name
      )),
      'trial_start', trial_start,
      'trial_end', trial_end,
      'in_trial', in_trial,
      'straight_from_free_tier', straight_from_free_tier
      ) as arguments
  from internal.paid_tenants
  group by
    catalog_name,
    tenant,
    alert_type,
    trial_start,
    trial_end,
    in_trial,
    straight_from_free_tier
)
select * from data_processing
union all select * from free_trial
union all select * from free_trial_ending
union all select * from delinquent_tenants
union all select * from paid_tenants
order by catalog_name asc;

create or replace function internal.send_alerts()
returns trigger as $trigger$
declare
  token text;
begin

select decrypted_secret into token from vault.decrypted_secrets where name = 'alert-email-fn-shared-secret' limit 1;

if new.alert_type = 'data_not_processed_in_interval' then
  perform
    net.http_post(
      'https://eyrcnmuzzyriypdajwdk.supabase.co/functions/v1/alert-data-processing',
      to_jsonb(new.*),
      headers:=format('{"Content-Type": "application/json", "Authorization": "Basic %s"}', token)::jsonb
    );
-- Skip all of the past events that got triggered when we added these new event types
-- NOTE: Change this so that the date is the day (or time) that it's deployed
-- so that only "real" events that happen after deployment get sent
else-- if new.fired_at > '2024-01-30'
  perform
    net.http_post(
      'http://host.docker.internal:5431/functions/v1/alerts',
      to_jsonb(new.*),
      headers:=format('{"Content-Type": "application/json", "Authorization": "Basic %s"}', token)::jsonb
    );
end if;

return null;
end;
$trigger$ LANGUAGE plpgsql;

create or replace trigger "Send email after alert fired" after insert on alert_history
  for each row execute procedure internal.send_alerts();

create or replace trigger "Send email after alert resolved" after update on alert_history
  for each row when (old.resolved_at is null and new.resolved_at is not null) execute procedure internal.send_alerts();

commit;