-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 0 — TABLE CREATION
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS raw_users (
    user_id         VARCHAR(20),
    signup_date     TIMESTAMP,
    country         VARCHAR(5),
    company_size    VARCHAR(20),
    signup_source   VARCHAR(30),
    email           VARCHAR(100),
    timezone        VARCHAR(40)
);

CREATE TABLE IF NOT EXISTS raw_events (
    event_id        VARCHAR(20),
    user_id         VARCHAR(20),
    event_name      VARCHAR(60),
    event_timestamp VARCHAR(50),   
    platform        VARCHAR(10),
    session_id      VARCHAR(15),
    country         VARCHAR(5),
    plan_type       VARCHAR(20),
    company_size    VARCHAR(20),
    properties      TEXT
);

CREATE TABLE IF NOT EXISTS raw_sessions (
    session_id      VARCHAR(15),
    user_id         VARCHAR(20),
    session_start   TIMESTAMP,
    session_end     TIMESTAMP,    
    n_events        INT,
    platform        VARCHAR(10),
    country         VARCHAR(5),
    plan_type       VARCHAR(20)
);

CREATE TABLE IF NOT EXISTS subscriptions (
    user_id          VARCHAR(20),
    plan_type        VARCHAR(20),
    mrr_usd          NUMERIC(10,2),
    conversion_date  DATE,
    churned          BOOLEAN,
    churn_date       DATE,
    company_size     VARCHAR(20),
    country          VARCHAR(5),
    subscription_id  VARCHAR(20)
);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1 — DATA CLEANING & QUALITY CHECKS
-- ─────────────────────────────────────────────────────────────────────────────

-- 1A. Identify and flag duplicate users 
WITH user_counts AS (
    SELECT
        user_id,
        COUNT(*) AS occurrences,
        MIN(signup_date::DATE) AS first_seen,
        MAX(signup_date::DATE) AS last_seen
    FROM raw_users
    GROUP BY user_id
),
duplicates AS (
    SELECT * FROM user_counts WHERE occurrences > 1
)
SELECT
    COUNT(*)                        AS total_duplicate_user_ids,
    SUM(occurrences - 1)            AS extra_rows_to_remove,
    ROUND(SUM(occurrences - 1) * 100.0 / (SELECT COUNT(*) FROM raw_users), 2) AS pct_duplicate
FROM duplicates;


-- 1B. Clean users — deduplicate, keep first record
CREATE OR REPLACE VIEW clean_users AS
SELECT DISTINCT ON (user_id)
    user_id,
    signup_date::TIMESTAMP              AS signup_date,
    country,
    COALESCE(company_size, 'unknown')   AS company_size,  -- fill NULLs
    signup_source,
    -- flag malformed emails (missing domain)
    CASE WHEN email NOT LIKE '%@%.%' THEN TRUE ELSE FALSE END AS email_invalid,
    timezone
FROM raw_users
ORDER BY user_id, signup_date ASC;


-- 1C. Parse and clean events — handle mixed timestamp formats
CREATE OR REPLACE VIEW clean_events AS
SELECT
    event_id,
    user_id,
    event_name,
    -- Handle two timestamp formats: ISO and DD/MM/YYYY HH:MM
    CASE
        WHEN event_timestamp ~ '^\d{4}-\d{2}-\d{2}'
            THEN event_timestamp::TIMESTAMP
        WHEN event_timestamp ~ '^\d{2}/\d{2}/\d{4}'
            THEN TO_TIMESTAMP(event_timestamp, 'DD/MM/YYYY HH24:MI')
        ELSE NULL
    END                                    AS event_timestamp,
    platform,
    session_id,
    COALESCE(country, 'unknown')           AS country,  -- fill NULL countries
    plan_type,
    COALESCE(company_size, 'unknown')      AS company_size,
    -- Flag malformed JSON properties
    CASE WHEN properties = 'NULL' OR properties IS NULL THEN NULL
         ELSE properties::JSONB END        AS properties
FROM raw_events
WHERE event_name IS NOT NULL
  AND user_id IS NOT NULL;


-- 1D. Data quality summary 
SELECT
    'raw_events'                                        AS table_name,
    COUNT(*)                                            AS total_rows,
    COUNT(CASE WHEN event_timestamp ~ '^\d{2}/\d{2}' THEN 1 END) AS bad_timestamps,
    COUNT(CASE WHEN country IS NULL THEN 1 END)         AS null_countries,
    COUNT(CASE WHEN properties = 'NULL' THEN 1 END)     AS malformed_properties,
    COUNT(DISTINCT user_id)                             AS unique_users,
    COUNT(DISTINCT session_id)                          AS unique_sessions
FROM raw_events;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2 — PRODUCT FUNNEL ANALYSIS
-- ─────────────────────────────────────────────────────────────────────────────

-- 2A. Full signup-to-paid funnel (waterfall)
WITH funnel_steps AS (
    SELECT
        u.user_id,
        -- Step 1: Signed up (everyone)
        1 AS step_1_signed_up,
        -- Step 2: Verified email
        MAX(CASE WHEN e.event_name = 'email_verified' THEN 1 ELSE 0 END)               AS step_2_email_verified,
        -- Step 3: Completed at least onboarding step 1
        MAX(CASE WHEN e.event_name = 'onboarding_step_1_completed' THEN 1 ELSE 0 END)  AS step_3_onboarding_started,
        -- Step 4: Completed full onboarding (step 3)
        MAX(CASE WHEN e.event_name = 'onboarding_step_3_completed' THEN 1 ELSE 0 END)  AS step_4_onboarding_complete,
        -- Step 5: AHA moment — connected data source
        MAX(CASE WHEN e.event_name = 'data_source_connected' THEN 1 ELSE 0 END)        AS step_5_aha_moment,
        -- Step 6: Viewed upgrade / pricing page
        MAX(CASE WHEN e.event_name IN ('upgrade_page_viewed','pricing_page_viewed')
                 THEN 1 ELSE 0 END)                                                    AS step_6_upgrade_intent,
        -- Step 7: Converted to paid
        MAX(CASE WHEN e.event_name = 'subscription_activated' THEN 1 ELSE 0 END)       AS step_7_converted
    FROM clean_users u
    LEFT JOIN clean_events e USING (user_id)
    GROUP BY u.user_id
),
funnel_counts AS (
    SELECT
        COUNT(*)                                    AS s1_signed_up,
        SUM(step_2_email_verified)                  AS s2_email_verified,
        SUM(step_3_onboarding_started)              AS s3_onboarding_started,
        SUM(step_4_onboarding_complete)             AS s4_onboarding_complete,
        SUM(step_5_aha_moment)                      AS s5_aha_moment,
        SUM(step_6_upgrade_intent)                  AS s6_upgrade_intent,
        SUM(step_7_converted)                       AS s7_converted
    FROM funnel_steps
)
SELECT
    'Step 1: Signed Up'             AS funnel_step, s1_signed_up   AS users,
    100.0                           AS pct_of_top,  NULL           AS step_dropoff_pct
FROM funnel_counts
UNION ALL SELECT 'Step 2: Email Verified',      s2_email_verified,
    ROUND(s2_email_verified * 100.0 / NULLIF(s1_signed_up,0),1),
    ROUND((s1_signed_up - s2_email_verified) * 100.0 / NULLIF(s1_signed_up,0),1)
FROM funnel_counts
UNION ALL SELECT 'Step 3: Onboarding Started',  s3_onboarding_started,
    ROUND(s3_onboarding_started * 100.0 / NULLIF(s1_signed_up,0),1),
    ROUND((s2_email_verified - s3_onboarding_started) * 100.0 / NULLIF(s2_email_verified,0),1)
FROM funnel_counts
UNION ALL SELECT 'Step 4: Onboarding Complete', s4_onboarding_complete,
    ROUND(s4_onboarding_complete * 100.0 / NULLIF(s1_signed_up,0),1),
    ROUND((s3_onboarding_started - s4_onboarding_complete) * 100.0 / NULLIF(s3_onboarding_started,0),1)
FROM funnel_counts
UNION ALL SELECT 'Step 5: AHA Moment',          s5_aha_moment,
    ROUND(s5_aha_moment * 100.0 / NULLIF(s1_signed_up,0),1),
    ROUND((s4_onboarding_complete - s5_aha_moment) * 100.0 / NULLIF(s4_onboarding_complete,0),1)
FROM funnel_counts
UNION ALL SELECT 'Step 6: Upgrade Intent',      s6_upgrade_intent,
    ROUND(s6_upgrade_intent * 100.0 / NULLIF(s1_signed_up,0),1),
    ROUND((s5_aha_moment - s6_upgrade_intent) * 100.0 / NULLIF(s5_aha_moment,0),1)
FROM funnel_counts
UNION ALL SELECT 'Step 7: Converted to Paid',   s7_converted,
    ROUND(s7_converted * 100.0 / NULLIF(s1_signed_up,0),1),
    ROUND((s6_upgrade_intent - s7_converted) * 100.0 / NULLIF(s6_upgrade_intent,0),1)
FROM funnel_counts
ORDER BY users DESC;


-- 2B. Funnel by company size — who converts best?
WITH funnel_by_segment AS (
    SELECT
        u.company_size,
        COUNT(DISTINCT u.user_id)                                              AS total_users,
        COUNT(DISTINCT CASE WHEN e.event_name = 'email_verified'
              THEN u.user_id END)                                              AS email_verified,
        COUNT(DISTINCT CASE WHEN e.event_name = 'data_source_connected'
              THEN u.user_id END)                                              AS aha_moment,
        COUNT(DISTINCT CASE WHEN e.event_name = 'subscription_activated'
              THEN u.user_id END)                                              AS converted
    FROM clean_users u
    LEFT JOIN clean_events e USING (user_id)
    GROUP BY u.company_size
)
SELECT
    company_size,
    total_users,
    ROUND(email_verified * 100.0 / NULLIF(total_users,0), 1)   AS email_verif_rate,
    ROUND(aha_moment * 100.0 / NULLIF(total_users,0), 1)        AS aha_rate,
    ROUND(converted * 100.0 / NULLIF(total_users,0), 1)         AS conversion_rate
FROM funnel_by_segment
ORDER BY conversion_rate DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3 — DAU / MAU / STICKINESS
-- ─────────────────────────────────────────────────────────────────────────────

-- 3A. Daily Active Users (DAU)
CREATE OR REPLACE VIEW dau AS
SELECT
    event_timestamp::DATE   AS activity_date,
    plan_type,
    COUNT(DISTINCT user_id) AS dau
FROM clean_events
WHERE event_timestamp IS NOT NULL
  AND event_name = 'session_started'
GROUP BY 1, 2;


-- 3B. Monthly Active Users (MAU)
CREATE OR REPLACE VIEW mau AS
SELECT
    DATE_TRUNC('month', event_timestamp)  AS activity_month,
    plan_type,
    COUNT(DISTINCT user_id)               AS mau
FROM clean_events
WHERE event_timestamp IS NOT NULL
  AND event_name = 'session_started'
GROUP BY 1, 2;


-- 3C. DAU/MAU ratio (stickiness score) — key metric for product health
WITH daily AS (
    SELECT
        activity_date,
        DATE_TRUNC('month', activity_date)  AS month,
        plan_type,
        dau
    FROM dau
),
monthly AS (SELECT activity_month, plan_type, mau FROM mau)
SELECT
    d.month,
    d.plan_type,
    ROUND(AVG(d.dau), 0)                         AS avg_dau,
    m.mau,
    ROUND(AVG(d.dau) * 100.0 / NULLIF(m.mau, 0), 1) AS stickiness_pct
FROM daily d
JOIN monthly m ON d.month = m.activity_month AND d.plan_type = m.plan_type
GROUP BY d.month, d.plan_type, m.mau
ORDER BY d.month, d.plan_type;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4 — COHORT RETENTION ANALYSIS
-- ─────────────────────────────────────────────────────────────────────────────

-- 4A. Monthly cohort retention (signup month vs. activity month)
WITH cohorts AS (
    SELECT
        user_id,
        DATE_TRUNC('month', signup_date) AS cohort_month
    FROM clean_users
),
user_activity AS (
    SELECT
        e.user_id,
        DATE_TRUNC('month', e.event_timestamp) AS activity_month
    FROM clean_events e
    WHERE e.event_timestamp IS NOT NULL
    GROUP BY 1, 2
),
cohort_activity AS (
    SELECT
        c.cohort_month,
        ua.activity_month,
        COUNT(DISTINCT c.user_id)                               AS active_users,
        DATE_PART('month', AGE(ua.activity_month, c.cohort_month)) AS months_since_signup
    FROM cohorts c
    JOIN user_activity ua USING (user_id)
    GROUP BY 1, 2, 4
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT user_id) AS cohort_size
    FROM cohorts GROUP BY 1
)
SELECT
    ca.cohort_month,
    cs.cohort_size,
    ca.months_since_signup::INT     AS month_number,
    ca.active_users,
    ROUND(ca.active_users * 100.0 / NULLIF(cs.cohort_size, 0), 1) AS retention_pct
FROM cohort_activity ca
JOIN cohort_sizes cs USING (cohort_month)
WHERE ca.months_since_signup BETWEEN 0 AND 11
ORDER BY ca.cohort_month, ca.months_since_signup;


-- 4B. 7-day, 14-day, 30-day retention by cohort signup week
WITH first_activity AS (
    SELECT user_id, MIN(event_timestamp)::DATE AS first_active
    FROM clean_events WHERE event_timestamp IS NOT NULL GROUP BY 1
),
return_activity AS (
    SELECT DISTINCT
        e.user_id,
        fa.first_active,
        (e.event_timestamp::DATE - fa.first_active) AS days_since_first
    FROM clean_events e
    JOIN first_activity fa USING (user_id)
    WHERE e.event_timestamp IS NOT NULL
)
SELECT
    DATE_TRUNC('week', first_active)        AS signup_week,
    COUNT(DISTINCT user_id)                 AS cohort_size,
    COUNT(DISTINCT CASE WHEN days_since_first BETWEEN 6  AND 8  THEN user_id END) AS retained_d7,
    COUNT(DISTINCT CASE WHEN days_since_first BETWEEN 13 AND 15 THEN user_id END) AS retained_d14,
    COUNT(DISTINCT CASE WHEN days_since_first BETWEEN 29 AND 31 THEN user_id END) AS retained_d30,
    ROUND(COUNT(DISTINCT CASE WHEN days_since_first BETWEEN 6  AND 8  THEN user_id END)
          * 100.0 / NULLIF(COUNT(DISTINCT user_id),0), 1) AS d7_retention_pct,
    ROUND(COUNT(DISTINCT CASE WHEN days_since_first BETWEEN 13 AND 15 THEN user_id END)
          * 100.0 / NULLIF(COUNT(DISTINCT user_id),0), 1) AS d14_retention_pct,
    ROUND(COUNT(DISTINCT CASE WHEN days_since_first BETWEEN 29 AND 31 THEN user_id END)
          * 100.0 / NULLIF(COUNT(DISTINCT user_id),0), 1) AS d30_retention_pct
FROM return_activity
GROUP BY 1
ORDER BY 1;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5 — AHA MOMENT ANALYSIS
-- ─────────────────────────────────────────────────────────────────────────────

-- 5A. Which feature, when used in first 3 days, best predicts conversion?
WITH early_features AS (
    SELECT
        e.user_id,
        e.event_name,
        EXTRACT(EPOCH FROM (e.event_timestamp - u.signup_date)) / 3600 AS hours_after_signup
    FROM clean_events e
    JOIN clean_users u USING (user_id)
    WHERE e.event_timestamp IS NOT NULL
      AND e.event_timestamp BETWEEN u.signup_date AND u.signup_date + INTERVAL '3 days'
      AND e.event_name IN (
            'data_source_connected','dashboard_created','workspace_created',
            'report_generated','teammate_invited','api_key_generated',
            'template_used','automation_configured'
      )
),
feature_conversion AS (
    SELECT
        ef.event_name                                           AS feature,
        COUNT(DISTINCT ef.user_id)                             AS users_who_used,
        COUNT(DISTINCT CASE WHEN s.subscription_id IS NOT NULL
              THEN ef.user_id END)                             AS users_who_converted,
        ROUND(AVG(ef.hours_after_signup)::NUMERIC, 1)          AS avg_hours_to_use
    FROM early_features ef
    LEFT JOIN subscriptions s USING (user_id)
    GROUP BY 1
)
SELECT
    feature,
    users_who_used,
    users_who_converted,
    ROUND(users_who_converted * 100.0 / NULLIF(users_who_used, 0), 1) AS conversion_rate_pct,
    avg_hours_to_use,
    -- Revenue uplift: if we increase usage of this feature by 1%
    ROUND(users_who_converted * 0.01 *
          (SELECT AVG(mrr_usd) FROM subscriptions), 0)         AS revenue_impact_1pct_increase
FROM feature_conversion
ORDER BY conversion_rate_pct DESC;


-- 5B. Time-to-activation: how fast do users hit the aha moment?
WITH aha_users AS (
    SELECT
        e.user_id,
        u.signup_date,
        MIN(e.event_timestamp) AS aha_timestamp,
        EXTRACT(EPOCH FROM (MIN(e.event_timestamp) - u.signup_date))/3600 AS hours_to_aha
    FROM clean_events e
    JOIN clean_users u USING (user_id)
    WHERE e.event_name = 'data_source_connected'
    GROUP BY e.user_id, u.signup_date
)
SELECT
    CASE
        WHEN hours_to_aha < 1    THEN '< 1 hour'
        WHEN hours_to_aha < 24   THEN '1–24 hours'
        WHEN hours_to_aha < 72   THEN '1–3 days'
        ELSE '3+ days'
    END                                 AS time_to_aha_bucket,
    COUNT(*)                            AS users,
    ROUND(AVG(hours_to_aha)::NUMERIC,1) AS avg_hours
FROM aha_users
GROUP BY 1
ORDER BY avg_hours;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6 — CHURN & REVENUE ANALYSIS
-- ─────────────────────────────────────────────────────────────────────────────

-- 6A. Monthly churn rate by plan
WITH monthly_active AS (
    SELECT
        DATE_TRUNC('month', conversion_date)  AS month,
        plan_type,
        COUNT(*)                               AS active_at_start
    FROM subscriptions
    WHERE conversion_date IS NOT NULL
    GROUP BY 1, 2
),
monthly_churned AS (
    SELECT
        DATE_TRUNC('month', churn_date)       AS month,
        plan_type,
        COUNT(*)                              AS churned
    FROM subscriptions
    WHERE churned = TRUE AND churn_date IS NOT NULL
    GROUP BY 1, 2
)
SELECT
    ma.month,
    ma.plan_type,
    ma.active_at_start,
    COALESCE(mc.churned, 0)                                        AS churned,
    ROUND(COALESCE(mc.churned, 0) * 100.0 / NULLIF(ma.active_at_start, 0), 2) AS churn_rate_pct
FROM monthly_active ma
LEFT JOIN monthly_churned mc ON ma.month = mc.month AND ma.plan_type = mc.plan_type
ORDER BY ma.month, ma.plan_type;


-- 6B. MRR growth — new MRR, expansion, churn (simplified waterfall)
WITH monthly_mrr AS (
    SELECT
        DATE_TRUNC('month', conversion_date)  AS month,
        SUM(mrr_usd)                           AS new_mrr,
        COUNT(*)                               AS new_customers
    FROM subscriptions
    WHERE conversion_date IS NOT NULL
    GROUP BY 1
),
churned_mrr AS (
    SELECT
        DATE_TRUNC('month', churn_date)       AS month,
        SUM(mrr_usd)                          AS churned_mrr,
        COUNT(*)                              AS churned_customers
    FROM subscriptions
    WHERE churned = TRUE AND churn_date IS NOT NULL
    GROUP BY 1
)
SELECT
    COALESCE(nm.month, cm.month)              AS month,
    COALESCE(nm.new_mrr, 0)                   AS new_mrr,
    COALESCE(cm.churned_mrr, 0)               AS churned_mrr,
    COALESCE(nm.new_mrr, 0) - COALESCE(cm.churned_mrr, 0) AS net_new_mrr,
    SUM(COALESCE(nm.new_mrr, 0) - COALESCE(cm.churned_mrr, 0))
        OVER (ORDER BY COALESCE(nm.month, cm.month))       AS cumulative_mrr,
    COALESCE(nm.new_customers, 0)             AS new_customers,
    COALESCE(cm.churned_customers, 0)         AS churned_customers
FROM monthly_mrr nm
FULL OUTER JOIN churned_mrr cm USING (month)
ORDER BY month;


-- 6C. Revenue at risk by segment
SELECT
    company_size,
    country,
    plan_type,
    COUNT(*)                   AS at_risk_customers,
    SUM(mrr_usd)               AS mrr_at_risk,
    ROUND(AVG(
        EXTRACT(EPOCH FROM (CURRENT_DATE - conversion_date::TIMESTAMP))/86400
    )::NUMERIC, 0)             AS avg_days_since_conversion
FROM subscriptions
WHERE churned = FALSE
  AND conversion_date < CURRENT_DATE - INTERVAL '60 days'
  AND user_id NOT IN (
      SELECT DISTINCT user_id FROM clean_events
      WHERE event_timestamp > CURRENT_TIMESTAMP - INTERVAL '30 days'
  )
GROUP BY 1, 2, 3
ORDER BY mrr_at_risk DESC
LIMIT 20;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7 — REVENUE IMPACT SIMULATOR
-- ─────────────────────────────────────────────────────────────────────────────

-- 7A. What is the revenue impact of improving conversion rate by 1%?
WITH baseline AS (
    SELECT
        COUNT(DISTINCT u.user_id)                       AS total_trial_users,
        COUNT(DISTINCT s.user_id)                       AS converted_users,
        ROUND(COUNT(DISTINCT s.user_id) * 100.0
              / NULLIF(COUNT(DISTINCT u.user_id), 0), 2) AS conversion_rate_pct,
        ROUND(AVG(s.mrr_usd), 2)                        AS avg_mrr_per_customer
    FROM clean_users u
    LEFT JOIN subscriptions s USING (user_id)
)
SELECT
    total_trial_users,
    converted_users,
    conversion_rate_pct,
    avg_mrr_per_customer,
    -- Impact of +1% conversion rate improvement
    ROUND(total_trial_users * 0.01 * avg_mrr_per_customer, 0) AS monthly_revenue_gain_1pct,
    ROUND(total_trial_users * 0.01 * avg_mrr_per_customer * 12, 0) AS annual_revenue_gain_1pct,
    -- Impact of +5% activation rate improvement  
    ROUND(total_trial_users * 0.05 * 0.45 * avg_mrr_per_customer, 0) AS monthly_gain_5pct_activation
FROM baseline;


-- 7B. Payback period by segment (LTV / CAC proxy)
WITH segment_metrics AS (
    SELECT
        plan_type,
        company_size,
        COUNT(*)                    AS customers,
        ROUND(AVG(mrr_usd), 2)      AS avg_mrr,
        ROUND(AVG(mrr_usd) * 12, 2) AS avg_arr,
        -- Rough LTV: avg MRR / monthly churn rate
        ROUND(AVG(mrr_usd) / NULLIF(
            SUM(CASE WHEN churned THEN 1 ELSE 0 END)::NUMERIC / NULLIF(COUNT(*),0)
        , 0), 0)                    AS ltv_estimate
    FROM subscriptions
    GROUP BY 1, 2
)
SELECT
    plan_type,
    company_size,
    customers,
    avg_mrr,
    avg_arr,
    ltv_estimate,
    -- If avg CAC for SaaS is assumed ~3x MRR (common benchmark)
    ROUND(avg_mrr * 3, 0)           AS estimated_cac,
    ROUND((avg_mrr * 3) / NULLIF(avg_mrr, 0), 1) AS payback_months
FROM segment_metrics
ORDER BY ltv_estimate DESC NULLS LAST;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 8 — POWER BI READY VIEWS 
-- ─────────────────────────────────────────────────────────────────────────────

-- These views are designed to be imported directly into Power BI as tables.

-- PBI_VIEW_1: Executive KPI Summary
CREATE OR REPLACE VIEW pbi_kpi_summary AS
SELECT
    COUNT(DISTINCT u.user_id)                           AS total_signups,
    COUNT(DISTINCT CASE WHEN e.event_name = 'data_source_connected'
          THEN u.user_id END)                           AS activated_users,
    COUNT(DISTINCT s.user_id)                           AS converted_users,
    ROUND(COUNT(DISTINCT CASE WHEN e.event_name = 'data_source_connected'
          THEN u.user_id END) * 100.0
          / NULLIF(COUNT(DISTINCT u.user_id),0), 1)     AS activation_rate_pct,
    ROUND(COUNT(DISTINCT s.user_id) * 100.0
          / NULLIF(COUNT(DISTINCT u.user_id),0), 1)     AS conversion_rate_pct,
    ROUND(SUM(s.mrr_usd), 0)                            AS total_mrr,
    ROUND(AVG(s.mrr_usd), 2)                            AS avg_mrr,
    COUNT(DISTINCT CASE WHEN s.churned THEN s.user_id END) AS churned_customers,
    ROUND(COUNT(DISTINCT CASE WHEN s.churned THEN s.user_id END) * 100.0
          / NULLIF(COUNT(DISTINCT s.user_id), 0), 1)    AS churn_rate_pct
FROM clean_users u
LEFT JOIN clean_events e USING (user_id)
LEFT JOIN subscriptions s USING (user_id);


-- PBI_VIEW_2: Monthly performance for trend analysis
CREATE OR REPLACE VIEW pbi_monthly_performance AS
SELECT
    DATE_TRUNC('month', u.signup_date)                          AS month,
    COUNT(DISTINCT u.user_id)                                   AS signups,
    COUNT(DISTINCT CASE WHEN e.event_name='data_source_connected'
          THEN u.user_id END)                                   AS activations,
    COUNT(DISTINCT s.user_id)                                   AS conversions,
    COALESCE(SUM(s.mrr_usd), 0)                                 AS new_mrr,
    ROUND(COUNT(DISTINCT s.user_id)*100.0
          /NULLIF(COUNT(DISTINCT u.user_id),0),1)               AS conversion_rate_pct
FROM clean_users u
LEFT JOIN clean_events e USING (user_id)
LEFT JOIN subscriptions s USING (user_id)
WHERE u.signup_date IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- PBI_VIEW_3: User-level table for drill-through
CREATE OR REPLACE VIEW pbi_user_detail AS
SELECT
    u.user_id,
    u.signup_date::DATE             AS signup_date,
    u.country,
    u.company_size,
    u.signup_source,
    s.plan_type,
    COALESCE(s.mrr_usd, 0)          AS mrr_usd,
    s.conversion_date,
    s.churned,
    s.churn_date,
    CASE WHEN e_aha.user_id IS NOT NULL THEN TRUE ELSE FALSE END AS activated,
    CASE WHEN s.user_id IS NOT NULL THEN TRUE ELSE FALSE END     AS converted
FROM clean_users u
LEFT JOIN subscriptions s USING (user_id)
LEFT JOIN (
    SELECT DISTINCT user_id FROM clean_events
    WHERE event_name = 'data_source_connected'
) e_aha USING (user_id);
