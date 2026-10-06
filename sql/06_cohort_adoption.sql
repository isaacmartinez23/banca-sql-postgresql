-- 06_cohort_adoption.sql
-- Pregunta de negocio 3:
--   ¿Qué tan rápido adoptan tarjeta y préstamo las cuentas, según el año en
--   que se abrieron?
--
-- Cohorte = año de apertura de la cuenta.
-- Edad    = meses completos transcurridos desde la apertura.
--
-- Por qué no basta comparar "cuántas tienen tarjeta" por cohorte: las cuentas
-- de 1993 llevan seis años de vida y las de 1997 apenas uno o dos, así que las
-- viejas siempre saldrían mejor. La comparación justa es a la misma edad.
--
-- Datos censurados: una cohorte solo se reporta a una edad si TODAS sus
-- cuentas ya cumplieron esa edad al cierre de los datos. Donde no, la celda
-- queda vacía (NULL), no en cero: todavía no se puede saber.
--
-- Requisito: haber corrido 02_clean.sql.
-- Ejecutar desde psql:  \i /docker-entrypoint-initdb.d/06_cohort_adoption.sql

\set ON_ERROR_STOP on
\pset pager off
\pset null '·'

CREATE SCHEMA IF NOT EXISTS analytics;
DROP MATERIALIZED VIEW IF EXISTS analytics.account_products CASCADE;
DROP FUNCTION IF EXISTS analytics.months_between(date, date);

-- Meses completos transcurridos entre dos fechas
CREATE FUNCTION analytics.months_between(from_date date, to_date date)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT (extract(year  FROM age(to_date, from_date)) * 12
          + extract(month FROM age(to_date, from_date)))::int;
$$;

------------------------------------------------------------------------------
-- Una fila por cuenta: cohorte, tiempo observado y fecha del primer producto
------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.account_products AS
WITH params AS (
    SELECT max(trans_date) AS as_of FROM clean.trans
),
first_card AS (
    SELECT d.account_id, min(c.issued_date) AS first_card_date
    FROM clean.card c
    JOIN clean.disp d ON d.disp_id = c.disp_id
    GROUP BY d.account_id
),
first_loan AS (
    SELECT account_id, min(granted_date) AS first_loan_date
    FROM clean.loan
    GROUP BY account_id
)
SELECT a.account_id, a.opened_date,
       extract(year FROM a.opened_date)::int                     AS cohort_year,
       p.as_of,
       analytics.months_between(a.opened_date, p.as_of)          AS observed_months,
       fc.first_card_date,
       analytics.months_between(a.opened_date, fc.first_card_date) AS months_to_card,
       fl.first_loan_date,
       analytics.months_between(a.opened_date, fl.first_loan_date) AS months_to_loan
FROM clean.account a
CROSS JOIN params p
LEFT JOIN first_card fc ON fc.account_id = a.account_id
LEFT JOIN first_loan fl ON fl.account_id = a.account_id;

CREATE UNIQUE INDEX ON analytics.account_products (account_id);

------------------------------------------------------------------------------
-- Curva de adopción: por cohorte y edad (0 a 60 meses), el porcentaje
-- acumulado de cuentas que obtuvo el producto antes de cumplir esa edad
------------------------------------------------------------------------------
CREATE VIEW analytics.cohort_adoption AS
WITH cohort AS (
    SELECT cohort_year,
           count(*)             AS accounts,
           min(observed_months) AS max_observable_age   -- la cuenta más joven manda
    FROM analytics.account_products
    GROUP BY cohort_year
),
grid AS (
    SELECT c.cohort_year, c.accounts, c.max_observable_age, g.age_months
    FROM cohort c
    CROSS JOIN generate_series(0, 60) AS g(age_months)
)
SELECT g.cohort_year, g.age_months, g.accounts, g.max_observable_age,
       (g.age_months <= g.max_observable_age) AS observable,
       CASE WHEN g.age_months <= g.max_observable_age
            THEN round(100.0 * count(*) FILTER (WHERE ap.months_to_card < g.age_months)
                             / g.accounts, 1)
       END AS card_pct,
       CASE WHEN g.age_months <= g.max_observable_age
            THEN round(100.0 * count(*) FILTER (WHERE ap.months_to_loan < g.age_months)
                             / g.accounts, 1)
       END AS loan_pct
FROM grid g
JOIN analytics.account_products ap USING (cohort_year)
GROUP BY g.cohort_year, g.age_months, g.accounts, g.max_observable_age;

------------------------------------------------------------------------------
-- Resultados
------------------------------------------------------------------------------
\echo
\echo '=== 1. La comparación ingenua: porcentaje con producto al cierre, por cohorte ==='
\echo '    (sesgada: las cohortes viejas han tenido más tiempo)'
SELECT cohort_year,
       count(*)                                                  AS accounts,
       min(observed_months)                                      AS min_months_observed,
       round(100.0 * count(first_card_date) / count(*), 1)       AS card_pct_ever,
       round(100.0 * count(first_loan_date) / count(*), 1)       AS loan_pct_ever
FROM analytics.account_products
GROUP BY cohort_year
ORDER BY cohort_year;

\echo
\echo '=== 2. Tarjeta: porcentaje acumulado de la cohorte, a la misma edad ==='
\echo '    (· = la cohorte todavía no llega completa a esa edad)'
SELECT cohort_year, accounts,
       max(card_pct) FILTER (WHERE age_months = 6)  AS m6,
       max(card_pct) FILTER (WHERE age_months = 12) AS m12,
       max(card_pct) FILTER (WHERE age_months = 24) AS m24,
       max(card_pct) FILTER (WHERE age_months = 36) AS m36,
       max(card_pct) FILTER (WHERE age_months = 48) AS m48,
       max(card_pct) FILTER (WHERE age_months = 60) AS m60
FROM analytics.cohort_adoption
GROUP BY cohort_year, accounts
ORDER BY cohort_year;

\echo
\echo '=== 3. Préstamo: porcentaje acumulado de la cohorte, a la misma edad ==='
SELECT cohort_year, accounts,
       max(loan_pct) FILTER (WHERE age_months = 6)  AS m6,
       max(loan_pct) FILTER (WHERE age_months = 12) AS m12,
       max(loan_pct) FILTER (WHERE age_months = 24) AS m24,
       max(loan_pct) FILTER (WHERE age_months = 36) AS m36,
       max(loan_pct) FILTER (WHERE age_months = 48) AS m48,
       max(loan_pct) FILTER (WHERE age_months = 60) AS m60
FROM analytics.cohort_adoption
GROUP BY cohort_year, accounts
ORDER BY cohort_year;

\echo
\echo '=== 4. ¿Efecto de la edad o del calendario? Tarjetas emitidas por cohorte y año ==='
\echo '    (porcentaje de las cuentas de la cohorte que recibió su primera tarjeta ese año)'
SELECT cohort_year, count(*) AS accounts,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_card_date) = 1993) / count(*), 1) AS y1993,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_card_date) = 1994) / count(*), 1) AS y1994,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_card_date) = 1995) / count(*), 1) AS y1995,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_card_date) = 1996) / count(*), 1) AS y1996,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_card_date) = 1997) / count(*), 1) AS y1997,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_card_date) = 1998) / count(*), 1) AS y1998
FROM analytics.account_products
GROUP BY cohort_year
ORDER BY cohort_year;

\echo
\echo '=== 5. Lo mismo para préstamos ==='
SELECT cohort_year, count(*) AS accounts,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_loan_date) = 1993) / count(*), 1) AS y1993,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_loan_date) = 1994) / count(*), 1) AS y1994,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_loan_date) = 1995) / count(*), 1) AS y1995,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_loan_date) = 1996) / count(*), 1) AS y1996,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_loan_date) = 1997) / count(*), 1) AS y1997,
       round(100.0 * count(*) FILTER (WHERE extract(year FROM first_loan_date) = 1998) / count(*), 1) AS y1998
FROM analytics.account_products
GROUP BY cohort_year
ORDER BY cohort_year;

\echo
\echo '=== 6. ¿A qué edad de la cuenta llega cada producto? (meses desde la apertura) ==='
SELECT v.product,
       count(*)                                                           AS accounts,
       min(v.months)                                                      AS min_months,
       percentile_cont(0.25) WITHIN GROUP (ORDER BY v.months)::numeric(6,1) AS p25,
       percentile_cont(0.50) WITHIN GROUP (ORDER BY v.months)::numeric(6,1) AS median,
       percentile_cont(0.75) WITHIN GROUP (ORDER BY v.months)::numeric(6,1) AS p75,
       max(v.months)                                                      AS max_months
FROM analytics.account_products ap
CROSS JOIN LATERAL (VALUES
    ('tarjeta',  ap.months_to_card),
    ('préstamo', ap.months_to_loan)
) AS v(product, months)
WHERE v.months IS NOT NULL
GROUP BY v.product
ORDER BY v.product;

\pset null ''