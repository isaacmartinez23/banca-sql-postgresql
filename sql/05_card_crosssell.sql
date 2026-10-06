-- 05_card_crosssell.sql
-- Pregunta de negocio 2:
--   ¿Qué clientes activos y sanos todavía no tienen tarjeta, y a cuáles
--   conviene ofrecérsela primero?
--
-- Unidad de análisis: una cuenta, vista al cierre de los datos (la fecha del
-- último movimiento) y descrita con sus últimos 12 meses.
--
-- Definiciones (explícitas para poder discutirlas y cambiarlas):
--   sin tarjeta = ninguna persona ligada a la cuenta tiene tarjeta
--   activa      = movimientos del cliente en al menos 10 de los últimos 12 meses
--                 (no cuentan intereses, comisiones ni penalizaciones, que los
--                 genera el banco)
--   sana        = sin saldo negativo ni penalizaciones en 12 meses, y sin
--                 préstamo malo (estatus B o D)
--
-- Priorización por parecido: se ofrece primero a las cuentas que se parecen a
-- las que ya tienen tarjeta, medido como el porcentaje de cuentas con tarjeta
-- en su mismo segmento de ingresos y edad. Se usa el ingreso mensual a la
-- cuenta porque tener tarjeta no lo cambia; el saldo y los retiros sí cambian
-- después de recibirla, y usarlos sería fuga de información.
--
-- Requisito: haber corrido 02_clean.sql.
-- Ejecutar desde psql:  \i /docker-entrypoint-initdb.d/05_card_crosssell.sql

\set ON_ERROR_STOP on
\pset pager off

CREATE SCHEMA IF NOT EXISTS analytics;
DROP MATERIALIZED VIEW IF EXISTS analytics.account_profile CASCADE;

------------------------------------------------------------------------------
-- Perfil de cada cuenta al cierre de los datos
------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.account_profile AS
WITH params AS (
    SELECT max(trans_date) AS as_of FROM clean.trans
),
recent AS (
    -- movimientos de los últimos 12 meses
    SELECT t.account_id, t.trans_date, t.direction, t.amount, t.balance, t.purpose,
           (t.operation IS NOT NULL
            AND t.purpose IS DISTINCT FROM 'statement_fee'
            AND t.purpose IS DISTINCT FROM 'penalty_interest') AS customer_movement
    FROM clean.trans t
    CROSS JOIN params p
    WHERE t.trans_date > p.as_of - interval '12 months'
),
activity AS (
    SELECT account_id,
           count(*) FILTER (WHERE customer_movement)                 AS movements_12m,
           count(DISTINCT date_trunc('month', trans_date))
               FILTER (WHERE customer_movement)                      AS active_months_12m,
           round(avg(balance), 2)                                    AS avg_balance_12m,
           min(balance)                                              AS min_balance_12m,
           round(coalesce(sum(amount)
               FILTER (WHERE direction = 'credit' AND customer_movement), 0) / 12, 2)
                                                                     AS avg_monthly_inflow_12m,
           count(*) FILTER (WHERE purpose = 'penalty_interest' AND amount > 0)
                                                                     AS penalties_12m
    FROM recent
    GROUP BY account_id
),
cards AS (
    SELECT d.account_id,
           count(*)                                           AS cards,
           min(c.issued_date)                                 AS first_card_date,
           (array_agg(c.card_type ORDER BY c.issued_date))[1] AS card_type
    FROM clean.card c
    JOIN clean.disp d ON d.disp_id = c.disp_id
    GROUP BY d.account_id
),
loans AS (
    SELECT account_id, count(*) AS loans, bool_or(is_bad) AS has_bad_loan
    FROM clean.loan
    GROUP BY account_id
)
SELECT a.account_id, p.as_of,
       c.client_id                                         AS owner_id,
       extract(year FROM age(p.as_of, c.birth_date))::int  AS owner_age,
       c.gender                                            AS owner_gender,
       dt.region, dt.avg_salary                            AS district_avg_salary,
       a.opened_date,
       (p.as_of - a.opened_date) / 30                      AS account_age_months,
       coalesce(act.movements_12m, 0)                      AS movements_12m,
       coalesce(act.active_months_12m, 0)                  AS active_months_12m,
       act.avg_balance_12m, act.min_balance_12m,
       coalesce(act.avg_monthly_inflow_12m, 0)             AS avg_monthly_inflow_12m,
       coalesce(act.penalties_12m, 0)                      AS penalties_12m,
       (k.account_id IS NOT NULL)                          AS has_card,
       k.card_type, k.first_card_date,
       coalesce(l.loans, 0) > 0                            AS has_loan,
       coalesce(l.has_bad_loan, false)                     AS has_bad_loan,
       -- definiciones de negocio
       coalesce(act.active_months_12m, 0) >= 10            AS is_active,
       (coalesce(act.min_balance_12m, 0) >= 0
        AND coalesce(act.penalties_12m, 0) = 0
        AND NOT coalesce(l.has_bad_loan, false))           AS is_healthy
FROM clean.account a
CROSS JOIN params p
JOIN clean.disp     d  ON d.account_id   = a.account_id AND d.role = 'owner'
JOIN clean.client   c  ON c.client_id    = d.client_id
JOIN clean.district dt ON dt.district_id = a.district_id
LEFT JOIN activity act ON act.account_id = a.account_id
LEFT JOIN cards    k   ON k.account_id   = a.account_id
LEFT JOIN loans    l   ON l.account_id   = a.account_id;

CREATE UNIQUE INDEX ON analytics.account_profile (account_id);

------------------------------------------------------------------------------
-- Segmentos: cuartil de ingresos x grupo de edad, con el porcentaje de cuentas
-- de cada segmento que ya tiene tarjeta (segment_penetration_pct)
------------------------------------------------------------------------------
CREATE VIEW analytics.account_segments AS
WITH seg AS (
    SELECT ap.*,
           ntile(4)  OVER (ORDER BY avg_monthly_inflow_12m) AS inflow_quartile,
           ntile(10) OVER (ORDER BY avg_monthly_inflow_12m) AS inflow_decile,
           CASE WHEN owner_age < 18 THEN '1. menos de 18'
                WHEN owner_age < 30 THEN '2. 18 a 29'
                WHEN owner_age < 45 THEN '3. 30 a 44'
                WHEN owner_age < 60 THEN '4. 45 a 59'
                ELSE                     '5. 60 o más' END AS age_band
    FROM analytics.account_profile ap
)
SELECT seg.*,
       count(*) OVER w AS segment_accounts,
       CASE
            -- menores de edad: su producto es la tarjeta junior, así que se
            -- comparan con su propio grupo de edad y no con su nivel de ingresos
            WHEN owner_age < 18
            THEN round(100.0 * avg(has_card::int) OVER b, 1)
            -- en segmentos con menos de 30 cuentas el porcentaje es poco
            -- fiable: se usa el de todo su cuartil de ingresos
            WHEN count(*) OVER w >= 30
            THEN round(100.0 * avg(has_card::int) OVER w, 1)
            ELSE round(100.0 * avg(has_card::int) OVER q, 1)
       END AS segment_penetration_pct
FROM seg
WINDOW w AS (PARTITION BY inflow_quartile, age_band),
       q AS (PARTITION BY inflow_quartile),
       b AS (PARTITION BY age_band);

------------------------------------------------------------------------------
-- ¿Dónde se concentra la tarjeta gold? Por decil de ingresos, entre las
-- cuentas que ya tienen tarjeta. Un decil es "objetivo gold" si ahí la gold es
-- al menos 1.5 veces más común que en general y hay 20 tarjetas o más.
------------------------------------------------------------------------------
CREATE VIEW analytics.gold_by_decile AS
WITH overall AS (
    SELECT avg((card_type = 'gold')::int) AS gold_share
    FROM analytics.account_profile
    WHERE has_card
)
SELECT s.inflow_decile,
       round(min(s.avg_monthly_inflow_12m))           AS from_inflow,
       round(max(s.avg_monthly_inflow_12m))           AS to_inflow,
       count(*)                                       AS accounts,
       count(*) FILTER (WHERE s.has_card)             AS with_card,
       count(*) FILTER (WHERE s.card_type = 'gold')   AS gold,
       round(100.0 * count(*) FILTER (WHERE s.card_type = 'gold')
                   / nullif(count(*) FILTER (WHERE s.has_card), 0), 1) AS gold_pct_of_cards,
       round(100.0 * o.gold_share, 1)                 AS overall_gold_pct,
       (count(*) FILTER (WHERE s.has_card) >= 20
        AND count(*) FILTER (WHERE s.card_type = 'gold')::numeric
            / nullif(count(*) FILTER (WHERE s.has_card), 0) >= 1.5 * o.gold_share) AS gold_target
FROM analytics.account_segments s
CROSS JOIN overall o
GROUP BY s.inflow_decile, o.gold_share;

------------------------------------------------------------------------------
-- Candidatas: sin tarjeta, activas y sanas, ordenadas por prioridad
------------------------------------------------------------------------------
CREATE VIEW analytics.card_candidates AS
SELECT row_number() OVER (ORDER BY s.segment_penetration_pct DESC,
                                   s.avg_monthly_inflow_12m DESC,
                                   s.account_id) AS priority,
       s.account_id, s.owner_id, s.owner_age, s.age_band,
       s.inflow_quartile, s.inflow_decile,
       s.avg_monthly_inflow_12m, s.avg_balance_12m, s.active_months_12m,
       s.account_age_months, s.has_loan,
       s.segment_penetration_pct,
       -- producto base: junior para menores, classic para el resto
       CASE WHEN s.owner_age < 18 THEN 'junior' ELSE 'classic' END AS suggested_card,
       -- además, oferta gold si su decil de ingresos es "objetivo gold"
       (s.owner_age >= 18 AND coalesce(g.gold_target, false))      AS gold_upsell
FROM analytics.account_segments s
LEFT JOIN analytics.gold_by_decile g USING (inflow_decile)
WHERE NOT s.has_card
  AND s.is_active
  AND s.is_healthy;

------------------------------------------------------------------------------
-- Resultados
------------------------------------------------------------------------------
\echo
\echo '=== 1. Penetración actual de tarjetas ==='
SELECT count(*)                             AS accounts,
       sum(has_card::int)                   AS with_card,
       round(100.0 * avg(has_card::int), 1) AS penetration_pct
FROM analytics.account_profile;

SELECT card_type,
       count(*)                                           AS accounts,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_of_cards
FROM analytics.account_profile
WHERE has_card
GROUP BY card_type
ORDER BY accounts DESC;

\echo
\echo '=== 2. Tarjetas emitidas por año y acumulado ==='
WITH by_year AS (
    SELECT extract(year FROM issued_date)::int AS year,
           count(*)                            AS cards_issued
    FROM clean.card
    GROUP BY 1
)
SELECT year, cards_issued,
       sum(cards_issued) OVER (ORDER BY year) AS cumulative
FROM by_year
ORDER BY year;

\echo
\echo '=== 3. Embudo: de todas las cuentas a las candidatas ==='
SELECT v.step, v.accounts,
       round(100.0 * v.accounts / s.total, 1) AS pct_of_all
FROM (
    SELECT count(*)                                                        AS total,
           count(*) FILTER (WHERE NOT has_card)                            AS no_card,
           count(*) FILTER (WHERE NOT has_card AND is_active)              AS active,
           count(*) FILTER (WHERE NOT has_card AND is_active AND is_healthy) AS eligible
    FROM analytics.account_profile
) s
CROSS JOIN LATERAL (VALUES
    ('1. todas las cuentas',      s.total),
    ('2. sin tarjeta',            s.no_card),
    ('3. y además activas',       s.active),
    ('4. y además sanas (candidatas)', s.eligible)
) AS v(step, accounts)
ORDER BY v.step;

\echo
\echo '=== 4. ¿Quién tiene tarjeta hoy? Penetración por ingresos y por edad ==='
SELECT inflow_quartile,
       round(min(avg_monthly_inflow_12m)) AS from_inflow,
       round(max(avg_monthly_inflow_12m)) AS to_inflow,
       count(*)                             AS accounts,
       sum(has_card::int)                   AS with_card,
       round(100.0 * avg(has_card::int), 1) AS penetration_pct
FROM analytics.account_segments
GROUP BY inflow_quartile
ORDER BY inflow_quartile;

SELECT age_band,
       count(*)                             AS accounts,
       sum(has_card::int)                   AS with_card,
       round(100.0 * avg(has_card::int), 1) AS penetration_pct
FROM analytics.account_segments
GROUP BY age_band
ORDER BY age_band;

\echo
\echo '=== 5. Tipo de tarjeta según ingresos (cuentas que ya tienen tarjeta) ==='
SELECT inflow_quartile,
       count(*) FILTER (WHERE card_type = 'junior')  AS junior,
       count(*) FILTER (WHERE card_type = 'classic') AS classic,
       count(*) FILTER (WHERE card_type = 'gold')    AS gold,
       round(100.0 * count(*) FILTER (WHERE card_type = 'gold') / count(*), 1) AS gold_pct
FROM analytics.account_segments
WHERE has_card
GROUP BY inflow_quartile
ORDER BY inflow_quartile;

\echo
\echo '=== 5b. ¿Dónde se concentra la tarjeta gold? Por decil de ingresos ==='
SELECT inflow_decile, from_inflow, to_inflow, accounts, with_card, gold,
       gold_pct_of_cards, overall_gold_pct, gold_target
FROM analytics.gold_by_decile
ORDER BY inflow_decile;

\echo
\echo '=== 6. Candidatas por prioridad (penetración de su segmento frente a la general) ==='
WITH overall AS (
    SELECT 100.0 * avg(has_card::int) AS pct FROM analytics.account_profile
)
SELECT CASE WHEN c.segment_penetration_pct >= 1.5 * o.pct THEN '1. alta (1.5 veces la penetración general o más)'
            WHEN c.segment_penetration_pct >= o.pct       THEN '2. media (igual o mayor a la general)'
            ELSE                                               '3. baja (menor a la general)' END AS priority_group,
       count(*)                             AS candidates,
       round(avg(c.segment_penetration_pct), 1) AS avg_segment_penetration,
       round(avg(c.avg_monthly_inflow_12m)) AS avg_monthly_inflow,
       round(avg(c.avg_balance_12m))        AS avg_balance,
       count(*) FILTER (WHERE c.suggested_card = 'junior')  AS suggest_junior,
       count(*) FILTER (WHERE c.suggested_card = 'classic') AS suggest_classic,
       count(*) FILTER (WHERE c.gold_upsell)                AS gold_upsell
FROM analytics.card_candidates c
CROSS JOIN overall o
GROUP BY 1
ORDER BY 1;

\echo
\echo '=== 7. Las 15 primeras candidatas ==='
SELECT priority, account_id, owner_age, inflow_quartile,
       avg_monthly_inflow_12m, avg_balance_12m,
       segment_penetration_pct, suggested_card, gold_upsell
FROM analytics.card_candidates
ORDER BY priority
LIMIT 15;