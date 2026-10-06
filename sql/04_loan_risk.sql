-- 04_loan_risk.sql
-- Pregunta de negocio 1:
--   ¿El comportamiento de la cuenta ANTES del préstamo anticipa el impago?
--
-- Unidad de análisis: un préstamo. Un préstamo es "malo" (is_bad) cuando su
-- estatus es B (terminado sin pagar) o D (vigente con adeudo).
--
-- Regla central: las variables se calculan solo con movimientos anteriores a
-- la fecha de otorgamiento. Usar lo que pasó después (por ejemplo, intereses
-- de penalización tras dejar de pagar) sería fuga de información: describe la
-- consecuencia del impago, no lo anticipa. La sección 5 lo demuestra.
--
-- Requisito: haber corrido 02_clean.sql.
-- Ejecutar desde psql:  \i /docker-entrypoint-initdb.d/04_loan_risk.sql

\set ON_ERROR_STOP on
\pset pager off

CREATE SCHEMA IF NOT EXISTS analytics;
DROP MATERIALIZED VIEW IF EXISTS analytics.loan_features CASCADE;

------------------------------------------------------------------------------
-- Tabla de variables: una fila por préstamo
------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.loan_features AS
WITH pre AS (
    -- movimientos de la cuenta anteriores al préstamo
    SELECT l.loan_id, t.trans_date, t.direction, t.amount, t.balance, t.purpose,
           ((extract(year  FROM l.granted_date) - extract(year  FROM t.trans_date)) * 12
           + extract(month FROM l.granted_date) - extract(month FROM t.trans_date))::int
               AS months_before,         -- 0 = mes del préstamo, 1 = mes anterior...
           min(t.trans_date) OVER (PARTITION BY l.loan_id) AS first_trans_date
    FROM clean.loan l
    JOIN clean.trans t ON t.account_id = l.account_id
                      AND t.trans_date < l.granted_date
),
history AS (
    -- todo el historial previo
    SELECT loan_id,
           count(*)                    AS pre_trans,
           round(avg(balance), 2)      AS pre_avg_balance,
           -- OJO: el mínimo de todo el historial casi siempre es el depósito de
           -- apertura (unos cientos), así que no describe el comportamiento.
           min(balance)                AS pre_min_balance,
           -- mínimo de los últimos 3 meses, sin contar el día de apertura
           min(balance) FILTER (WHERE months_before <= 3 AND trans_date > first_trans_date)
                                       AS min_balance_last3m,
           bool_or(balance < 0)        AS pre_had_negative,
           count(*) FILTER (WHERE purpose = 'penalty_interest' AND amount > 0)
                                       AS pre_penalties
    FROM pre
    GROUP BY loan_id
),
monthly AS (
    -- un renglón por mes completo previo al préstamo
    SELECT loan_id, months_before,
           coalesce(sum(amount) FILTER (WHERE direction = 'credit'), 0) AS inflow,
           coalesce(sum(amount) FILTER (WHERE direction = 'debit'),  0) AS outflow,
           avg(balance)                                                 AS avg_balance
    FROM pre
    WHERE months_before >= 1
    GROUP BY loan_id, months_before
),
monthly_lag AS (
    -- saldo del mes anterior, para saber si el saldo venía cayendo
    SELECT *,
           lag(avg_balance) OVER (PARTITION BY loan_id ORDER BY months_before DESC)
               AS prev_month_balance
    FROM monthly
),
flows AS (
    SELECT loan_id,
           round(avg(inflow), 2)  AS avg_monthly_inflow,
           round(avg(outflow), 2) AS avg_monthly_outflow,
           round(avg(avg_balance) FILTER (WHERE months_before BETWEEN 1 AND 3), 2) AS balance_last3m,
           round(avg(avg_balance) FILTER (WHERE months_before BETWEEN 4 AND 6), 2) AS balance_prev3m,
           count(*) FILTER (WHERE months_before <= 6 AND avg_balance < prev_month_balance)
                                  AS months_declining_last6
    FROM monthly_lag
    GROUP BY loan_id
),
ever AS (
    -- historial COMPLETO, incluido lo posterior al préstamo.
    -- Solo se usa en la sección 5 para mostrar la fuga de información.
    SELECT l.loan_id,
           bool_or(t.balance < 0) AS ever_had_negative,
           count(*) FILTER (WHERE t.purpose = 'penalty_interest' AND t.amount > 0)
                                  AS ever_penalties
    FROM clean.loan l
    JOIN clean.trans t ON t.account_id = l.account_id
    GROUP BY l.loan_id
)
SELECT l.loan_id, l.account_id, l.granted_date, l.amount, l.duration_months,
       l.monthly_payment, l.status, l.is_bad,
       -- titular y contexto
       extract(year FROM age(l.granted_date, c.birth_date))::int AS owner_age,
       c.gender                                                   AS owner_gender,
       dt.avg_salary                                              AS district_avg_salary,
       (l.granted_date - a.opened_date) / 30                      AS account_age_months,
       -- comportamiento previo
       h.pre_trans, h.pre_avg_balance, h.pre_min_balance, h.min_balance_last3m,
       h.pre_had_negative, h.pre_penalties,
       -- la cuenta ya mostraba problemas antes de recibir el préstamo
       (coalesce(h.pre_had_negative, false) OR coalesce(h.pre_penalties, 0) > 0)
           AS pre_distress,
       f.avg_monthly_inflow, f.avg_monthly_outflow,
       -- qué tan pesada es la mensualidad frente a lo que entra a la cuenta
       round(l.monthly_payment / nullif(f.avg_monthly_inflow, 0), 3) AS payment_to_inflow,
       -- qué tan grande es el préstamo frente al saldo habitual
       round(l.amount / nullif(h.pre_avg_balance, 0), 2)             AS amount_to_avg_balance,
       f.balance_last3m, f.balance_prev3m,
       round(100 * (f.balance_last3m - f.balance_prev3m) / nullif(f.balance_prev3m, 0), 1)
                                                                     AS balance_trend_pct,
       f.months_declining_last6,
       -- solo para la sección 5
       e.ever_had_negative, e.ever_penalties
FROM clean.loan l
JOIN clean.account  a  ON a.account_id   = l.account_id
JOIN clean.disp     dp ON dp.account_id  = l.account_id AND dp.role = 'owner'
JOIN clean.client   c  ON c.client_id    = dp.client_id
JOIN clean.district dt ON dt.district_id = a.district_id
LEFT JOIN history h ON h.loan_id = l.loan_id
LEFT JOIN flows   f ON f.loan_id = l.loan_id
LEFT JOIN ever    e ON e.loan_id = l.loan_id;

-- Garantiza una fila por préstamo y permite REFRESH ... CONCURRENTLY
CREATE UNIQUE INDEX ON analytics.loan_features (loan_id);

-- Variables numéricas en formato largo (una fila por préstamo y variable),
-- para analizarlas todas con una misma consulta.
CREATE VIEW analytics.loan_feature_long AS
SELECT lf.loan_id, lf.is_bad, v.feature, v.value
FROM analytics.loan_features lf
CROSS JOIN LATERAL (VALUES
    ('amount',                lf.amount::numeric),
    ('monthly_payment',       lf.monthly_payment::numeric),
    ('owner_age',             lf.owner_age::numeric),
    ('account_age_months',    lf.account_age_months::numeric),
    ('pre_avg_balance',       lf.pre_avg_balance),
    ('min_balance_last3m',    lf.min_balance_last3m),
    ('avg_monthly_inflow',    lf.avg_monthly_inflow),
    ('payment_to_inflow',     lf.payment_to_inflow),
    ('amount_to_avg_balance', lf.amount_to_avg_balance),
    ('balance_trend_pct',     lf.balance_trend_pct)
) AS v(feature, value)
WHERE v.value IS NOT NULL;

-- Tasa de impago por cuartil de cada variable (Q1 = valores más bajos).
CREATE VIEW analytics.loan_feature_quartiles AS
WITH q AS (
    SELECT *, ntile(4) OVER (PARTITION BY feature ORDER BY value) AS quartile
    FROM analytics.loan_feature_long
)
SELECT feature, quartile,
       count(*)                           AS loans,
       round(min(value), 2)               AS from_value,
       round(max(value), 2)               AS to_value,
       sum(is_bad::int)                   AS bad_loans,
       round(100.0 * avg(is_bad::int), 1) AS bad_rate_pct
FROM q
GROUP BY feature, quartile;

------------------------------------------------------------------------------
-- Resultados
------------------------------------------------------------------------------
\echo
\echo '=== 1. Tasa base de impago ==='
SELECT status,
       CASE status WHEN 'A' THEN 'terminado, pagado'
                   WHEN 'B' THEN 'terminado, sin pagar'
                   WHEN 'C' THEN 'vigente, al corriente'
                   WHEN 'D' THEN 'vigente, con adeudo' END AS meaning,
       count(*) AS loans,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM analytics.loan_features
GROUP BY status
ORDER BY status;

SELECT count(*)                           AS loans,
       sum(is_bad::int)                   AS bad_loans,
       round(100.0 * avg(is_bad::int), 1) AS bad_rate_pct
FROM analytics.loan_features;

\echo
\echo '=== 2. Perfil: mediana de cada variable en préstamos buenos y malos ==='
SELECT feature,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY value)
              FILTER (WHERE NOT is_bad))::numeric, 2) AS median_good,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY value)
              FILTER (WHERE is_bad))::numeric, 2)     AS median_bad
FROM analytics.loan_feature_long
GROUP BY feature
ORDER BY feature;

\echo
\echo '=== 3. Qué variables separan mejor: diferencia entre el cuartil con más y con menos impago ==='
SELECT feature,
       min(bad_rate_pct)                     AS lowest_quartile_rate,
       max(bad_rate_pct)                     AS highest_quartile_rate,
       max(bad_rate_pct) - min(bad_rate_pct) AS spread_pts
FROM analytics.loan_feature_quartiles
GROUP BY feature
ORDER BY spread_pts DESC;

\echo
\echo '=== 4. Tasa de impago por cuartil (Q1 = valores más bajos) ==='
SELECT feature, quartile, loans, from_value, to_value, bad_loans, bad_rate_pct,
       round(bad_rate_pct / (SELECT 100.0 * avg(is_bad::int) FROM analytics.loan_features), 2)
           AS lift_vs_base
FROM analytics.loan_feature_quartiles
ORDER BY feature, quartile;

\echo
\echo '=== 5. Fuga de información: la misma señal medida antes del préstamo y en todo el historial ==='
SELECT v.signal, v.flag,
       count(*)                              AS loans,
       sum(lf.is_bad::int)                   AS bad_loans,
       round(100.0 * avg(lf.is_bad::int), 1) AS bad_rate_pct
FROM analytics.loan_features lf
CROSS JOIN LATERAL (VALUES
    ('1. saldo negativo ANTES del préstamo',   coalesce(lf.pre_had_negative, false)),
    ('2. saldo negativo en TODO el historial', coalesce(lf.ever_had_negative, false)),
    ('3. penalización ANTES del préstamo',     coalesce(lf.pre_penalties, 0) > 0),
    ('4. penalización en TODO el historial',   coalesce(lf.ever_penalties, 0) > 0)
) AS v(signal, flag)
GROUP BY v.signal, v.flag
ORDER BY v.signal, v.flag;

\echo
\echo '=== 6. Préstamos a titulares menores de edad ==='
SELECT CASE WHEN owner_age < 18 THEN 'menor de edad' ELSE 'adulto' END AS owner,
       count(*)                           AS loans,
       sum(is_bad::int)                   AS bad_loans,
       round(100.0 * avg(is_bad::int), 1) AS bad_rate_pct
FROM analytics.loan_features
GROUP BY 1
ORDER BY 1;

\echo
\echo '=== 7. ¿Las señales se sostienen sin las cuentas que ya tenían problemas? ==='
\echo '    (solo préstamos sin sobregiro ni penalización previos; cuartiles recalculados)'
WITH clean_start AS (
    SELECT lf.is_bad, v.feature, v.value
    FROM analytics.loan_features lf
    CROSS JOIN LATERAL (VALUES
        ('amount_to_avg_balance', lf.amount_to_avg_balance),
        ('payment_to_inflow',     lf.payment_to_inflow),
        ('balance_trend_pct',     lf.balance_trend_pct),
        ('pre_avg_balance',       lf.pre_avg_balance),
        ('min_balance_last3m',    lf.min_balance_last3m),
        ('account_age_months',    lf.account_age_months::numeric)
    ) AS v(feature, value)
    WHERE NOT lf.pre_distress
      AND v.value IS NOT NULL
),
q AS (
    SELECT *, ntile(4) OVER (PARTITION BY feature ORDER BY value) AS quartile
    FROM clean_start
)
SELECT feature, quartile,
       count(*)                           AS loans,
       round(min(value), 2)               AS from_value,
       round(max(value), 2)               AS to_value,
       sum(is_bad::int)                   AS bad_loans,
       round(100.0 * avg(is_bad::int), 1) AS bad_rate_pct
FROM q
GROUP BY feature, quartile
ORDER BY feature, quartile;

\echo
\echo '=== 8. ¿Antigüedad de la cuenta y tamaño del préstamo son señales distintas? ==='
\echo '    (solo préstamos sin sobregiro ni penalización previos)'
WITH base AS (
    SELECT is_bad,
           account_age_months <= 8 AS new_account,
           ntile(4) OVER (ORDER BY amount_to_avg_balance) = 4 AS large_loan
    FROM analytics.loan_features
    WHERE NOT pre_distress
      AND amount_to_avg_balance IS NOT NULL
)
SELECT CASE WHEN new_account THEN '1. cuenta de 8 meses o menos'
            ELSE '2. cuenta de más de 8 meses' END AS account_age,
       CASE WHEN large_loan THEN 'préstamo grande frente al saldo'
            ELSE 'préstamo normal' END AS loan_size,
       count(*)                           AS loans,
       sum(is_bad::int)                   AS bad_loans,
       round(100.0 * avg(is_bad::int), 1) AS bad_rate_pct
FROM base
GROUP BY 1, 2
ORDER BY 1, 2;

------------------------------------------------------------------------------
-- Regla de alerta temprana: cuatro niveles de riesgo al momento de otorgar.
--   cuenta nueva    = 8 meses o menos de antigüedad (primer cuartil, sección 7)
--   préstamo grande = cuartil más alto de monto / saldo promedio previo,
--                     calculado entre los préstamos sin problemas previos
-- Queda como vista para poder consultarla por préstamo.
------------------------------------------------------------------------------
CREATE VIEW analytics.loan_risk_tier AS
WITH flags AS (
    SELECT lf.*,
           coalesce(lf.account_age_months <= 8, false) AS new_account,
           coalesce(
               CASE WHEN NOT lf.pre_distress AND lf.amount_to_avg_balance IS NOT NULL
                    THEN ntile(4) OVER (
                             PARTITION BY (NOT lf.pre_distress AND lf.amount_to_avg_balance IS NOT NULL)
                             ORDER BY lf.amount_to_avg_balance) = 4
               END, false) AS large_loan
    FROM analytics.loan_features lf
)
SELECT loan_id, account_id, granted_date, amount, status, is_bad,
       pre_distress, new_account, large_loan,
       CASE WHEN pre_distress               THEN 1
            WHEN new_account AND large_loan THEN 2
            WHEN new_account OR  large_loan THEN 3
            ELSE                                 4
       END AS risk_tier
FROM flags;

\echo
\echo '=== 9. Regla de alerta temprana: cuatro niveles de riesgo ==='
SELECT risk_tier,
       CASE risk_tier
            WHEN 1 THEN 'sobregiro o penalización antes del préstamo'
            WHEN 2 THEN 'cuenta nueva y préstamo grande'
            WHEN 3 THEN 'cuenta nueva o préstamo grande'
            ELSE        'ninguna señal'
       END AS description,
       count(*)                           AS loans,
       sum(is_bad::int)                   AS bad_loans,
       round(100.0 * avg(is_bad::int), 1) AS bad_rate_pct,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1)                 AS pct_of_loans,
       round(100.0 * sum(is_bad::int) / sum(sum(is_bad::int)) OVER (), 1) AS pct_of_bad_loans,
       round(100.0 * sum(sum(is_bad::int)) OVER (ORDER BY risk_tier)
                   / sum(sum(is_bad::int)) OVER (), 1)                    AS cumulative_pct_of_bad
FROM analytics.loan_risk_tier
GROUP BY risk_tier
ORDER BY risk_tier;