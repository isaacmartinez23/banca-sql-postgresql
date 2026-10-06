-- 03_quality.sql
-- Pruebas de calidad de datos sobre el esquema clean.
--
-- Convención (la misma que usa dbt): cada prueba es una consulta que devuelve
-- las filas que VIOLAN una regla. Cero filas = la prueba pasa.
--
-- Las llaves y los CHECK de 02_clean.sql ya garantizan unicidad de IDs,
-- integridad referencial y dominios válidos. Aquí se prueba lo que una
-- restricción no puede expresar: reglas entre tablas, coherencia temporal y
-- que los saldos cuadren.
--
-- Severidad:
--   error = no debería pasar nunca; si falla, hay que investigar
--   warn  = no es necesariamente un error; se documenta como hallazgo
--
-- Requisito: haber corrido 02_clean.sql.
-- Ejecutar desde psql:  \i /docker-entrypoint-initdb.d/03_quality.sql
--
-- Para ver las filas que fallan en una prueba:
--   SELECT query FROM quality.test WHERE test_name = 'nombre_de_la_prueba' \gexec
--
-- Para volver a correr todas sin recrear nada:  CALL quality.run_all();

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS quality CASCADE;
CREATE SCHEMA quality;

CREATE TABLE quality.test (
    test_id     int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category    text NOT NULL,
    test_name   text NOT NULL UNIQUE,
    severity    text NOT NULL CHECK (severity IN ('error', 'warn')),
    description text NOT NULL,
    query       text NOT NULL      -- devuelve las filas que violan la regla
);

CREATE TABLE quality.result (
    run_at       timestamptz NOT NULL,
    test_id      int    NOT NULL REFERENCES quality.test,
    failing_rows bigint NOT NULL,
    PRIMARY KEY (run_at, test_id)
);

-- Ejecuta todas las pruebas y guarda cuántas filas fallan en cada una.
CREATE PROCEDURE quality.run_all()
LANGUAGE plpgsql AS $$
DECLARE
    t      record;
    n      bigint;
    run_ts timestamptz := clock_timestamp();
BEGIN
    FOR t IN SELECT test_id, query FROM quality.test ORDER BY test_id LOOP
        EXECUTE format('SELECT count(*) FROM (%s) q', t.query) INTO n;
        INSERT INTO quality.result VALUES (run_ts, t.test_id, n);
    END LOOP;
END;
$$;

-- Resultado de la corrida más reciente.
CREATE VIEW quality.report AS
SELECT t.test_id, t.category, t.test_name, t.severity, r.failing_rows,
       CASE WHEN r.failing_rows = 0     THEN 'ok'
            WHEN t.severity = 'error'   THEN 'FALLA'
            ELSE 'aviso' END AS status,
       t.description
FROM quality.test t
JOIN quality.result r USING (test_id)
WHERE r.run_at = (SELECT max(run_at) FROM quality.result);

------------------------------------------------------------------------------
-- Definición de las pruebas
------------------------------------------------------------------------------
INSERT INTO quality.test (category, test_name, severity, description, query) VALUES

-- 1. Volumen ---------------------------------------------------------------
('volumen', 'row_counts_raw_vs_clean', 'error',
 'Ninguna tabla pierde ni gana filas entre raw y clean',
 $q$
 SELECT * FROM (VALUES
     ('district', (SELECT count(*) FROM raw.district), (SELECT count(*) FROM clean.district)),
     ('account',  (SELECT count(*) FROM raw.account),  (SELECT count(*) FROM clean.account)),
     ('client',   (SELECT count(*) FROM raw.client),   (SELECT count(*) FROM clean.client)),
     ('disp',     (SELECT count(*) FROM raw.disp),     (SELECT count(*) FROM clean.disp)),
     ('orders',   (SELECT count(*) FROM raw.orders),   (SELECT count(*) FROM clean.orders)),
     ('loan',     (SELECT count(*) FROM raw.loan),     (SELECT count(*) FROM clean.loan)),
     ('card',     (SELECT count(*) FROM raw.card),     (SELECT count(*) FROM clean.card)),
     ('trans',    (SELECT count(*) FROM raw.trans),    (SELECT count(*) FROM clean.trans))
 ) v(table_name, raw_rows, clean_rows)
 WHERE raw_rows <> clean_rows
 $q$),

('volumen', 'row_counts_vs_published', 'warn',
 'Los conteos coinciden con los publicados para el dataset original',
 $q$
 SELECT * FROM (VALUES
     ('district', (SELECT count(*) FROM clean.district), 77),
     ('account',  (SELECT count(*) FROM clean.account),  4500),
     ('client',   (SELECT count(*) FROM clean.client),   5369),
     ('disp',     (SELECT count(*) FROM clean.disp),     5369),
     ('orders',   (SELECT count(*) FROM clean.orders),   6471),
     ('loan',     (SELECT count(*) FROM clean.loan),     682),
     ('card',     (SELECT count(*) FROM clean.card),     892),
     ('trans',    (SELECT count(*) FROM clean.trans),    1056320)
 ) v(table_name, clean_rows, published_rows)
 WHERE clean_rows <> published_rows
 $q$),

-- 2. Duplicados ------------------------------------------------------------
('duplicados', 'trans_exact_duplicates', 'error',
 'No hay transacciones repetidas con distinto ID (misma cuenta, fecha, tipo, monto y saldo)',
 $q$
 SELECT account_id, trans_date, direction, operation, amount, balance,
        count(*) AS copies
 FROM clean.trans
 WHERE amount > 0
 GROUP BY account_id, trans_date, direction, operation, amount, balance
 HAVING count(*) > 1
 $q$),

-- 3. Relaciones entre tablas -----------------------------------------------
('relaciones', 'account_without_single_owner', 'error',
 'Cada cuenta tiene exactamente un titular',
 $q$
 SELECT a.account_id,
        count(*) FILTER (WHERE d.role = 'owner') AS owners
 FROM clean.account a
 LEFT JOIN clean.disp d USING (account_id)
 GROUP BY a.account_id
 HAVING count(*) FILTER (WHERE d.role = 'owner') <> 1
 $q$),

('relaciones', 'client_without_account', 'error',
 'Todo cliente está ligado al menos a una cuenta',
 $q$
 SELECT c.client_id
 FROM clean.client c
 WHERE NOT EXISTS (SELECT 1 FROM clean.disp d WHERE d.client_id = c.client_id)
 $q$),

('relaciones', 'account_without_transactions', 'error',
 'Toda cuenta tiene al menos una transacción',
 $q$
 SELECT a.account_id
 FROM clean.account a
 WHERE NOT EXISTS (SELECT 1 FROM clean.trans t WHERE t.account_id = a.account_id)
 $q$),

('relaciones', 'account_with_multiple_loans', 'warn',
 'Una cuenta tiene a lo más un préstamo',
 $q$
 SELECT account_id, count(*) AS loans
 FROM clean.loan
 GROUP BY account_id
 HAVING count(*) > 1
 $q$),

-- 4. Coherencia temporal ---------------------------------------------------
('fechas', 'dates_out_of_range', 'error',
 'Todas las fechas de operación caen entre 1993 y 1998',
 $q$
 SELECT * FROM (
     SELECT 'account' AS table_name, account_id AS id, opened_date AS d FROM clean.account
     UNION ALL SELECT 'loan',  loan_id,  granted_date FROM clean.loan
     UNION ALL SELECT 'card',  card_id,  issued_date  FROM clean.card
     UNION ALL SELECT 'trans', trans_id, trans_date   FROM clean.trans
 ) x
 WHERE d NOT BETWEEN date '1993-01-01' AND date '1998-12-31'
 $q$),

('fechas', 'trans_before_account_opened', 'error',
 'Ninguna transacción es anterior a la apertura de su cuenta',
 $q$
 SELECT t.trans_id, t.account_id, t.trans_date, a.opened_date
 FROM clean.trans t
 JOIN clean.account a USING (account_id)
 WHERE t.trans_date < a.opened_date
 $q$),

('fechas', 'loan_granted_before_account_opened', 'error',
 'Ningún préstamo se otorga antes de abrir la cuenta',
 $q$
 SELECT l.loan_id, l.account_id, l.granted_date, a.opened_date
 FROM clean.loan l
 JOIN clean.account a USING (account_id)
 WHERE l.granted_date < a.opened_date
 $q$),

('fechas', 'card_issued_before_account_opened', 'error',
 'Ninguna tarjeta se emite antes de abrir la cuenta',
 $q$
 SELECT c.card_id, d.account_id, c.issued_date, a.opened_date
 FROM clean.card c
 JOIN clean.disp d USING (disp_id)
 JOIN clean.account a USING (account_id)
 WHERE c.issued_date < a.opened_date
 $q$),

('fechas', 'owner_minor_at_account_opening', 'warn',
 'El titular es mayor de edad al abrir la cuenta',
 $q$
 SELECT a.account_id, c.client_id, c.birth_date, a.opened_date,
        extract(year FROM age(a.opened_date, c.birth_date))::int AS age_at_opening
 FROM clean.account a
 JOIN clean.disp d USING (account_id)
 JOIN clean.client c USING (client_id)
 WHERE d.role = 'owner'
   AND age(a.opened_date, c.birth_date) < interval '18 years'
 $q$),

-- 5. Reglas de negocio de préstamos ----------------------------------------
('prestamos', 'loan_amount_vs_payments', 'error',
 'El monto del préstamo es igual a mensualidad por número de meses',
 $q$
 SELECT loan_id, amount, monthly_payment, duration_months,
        monthly_payment * duration_months AS expected_amount
 FROM clean.loan
 WHERE abs(amount - monthly_payment * duration_months) > duration_months
 $q$),

('prestamos', 'loan_status_vs_end_date', 'warn',
 'Los préstamos terminados (A, B) vencen antes de 1999 y los vigentes (C, D) después',
 $q$
 SELECT loan_id, status, granted_date, duration_months,
        (granted_date + make_interval(months => duration_months))::date AS end_date
 FROM clean.loan
 WHERE (status IN ('A', 'B')
        AND granted_date + make_interval(months => duration_months) > date '1998-12-31')
    OR (status IN ('C', 'D')
        AND granted_date + make_interval(months => duration_months) <= date '1998-12-31')
 $q$),

('prestamos', 'loan_without_payments', 'warn',
 'Todo préstamo tiene al menos un pago registrado en las transacciones',
 $q$
 SELECT l.loan_id, l.account_id, l.status
 FROM clean.loan l
 WHERE NOT EXISTS (SELECT 1 FROM clean.trans t
                   WHERE t.account_id = l.account_id
                     AND t.purpose = 'loan_payment')
 $q$),

('prestamos', 'loan_payment_amount_mismatch', 'warn',
 'Cada pago de préstamo coincide con la mensualidad pactada',
 $q$
 SELECT t.trans_id, t.account_id, t.trans_date, t.amount, l.monthly_payment
 FROM clean.trans t
 JOIN clean.loan l USING (account_id)
 WHERE t.purpose = 'loan_payment'
   AND abs(t.amount - l.monthly_payment) > 1
   AND (SELECT count(*) FROM clean.loan l2 WHERE l2.account_id = t.account_id) = 1
 $q$),

-- 6. Coherencia interna de las transacciones -------------------------------
('transacciones', 'trans_direction_vs_operation', 'error',
 'El sentido (abono/cargo) es coherente con la operación',
 $q$
 SELECT trans_id, account_id, direction, operation
 FROM clean.trans
 WHERE (direction = 'credit' AND operation IN ('cash_withdrawal', 'card_withdrawal', 'transfer_out'))
    OR (direction = 'debit'  AND operation IN ('cash_deposit', 'transfer_in'))
 $q$),

('transacciones', 'trans_zero_amount', 'warn',
 'No hay transacciones con monto cero',
 $q$
 SELECT trans_id, account_id, trans_date, operation, purpose
 FROM clean.trans
 WHERE amount = 0
 $q$),

('transacciones', 'trans_without_operation_not_interest', 'warn',
 'Solo los abonos de intereses carecen de operación',
 $q$
 SELECT trans_id, account_id, trans_date, direction, purpose
 FROM clean.trans
 WHERE operation IS NULL
   AND purpose IS DISTINCT FROM 'interest_credited'
 $q$),

('transacciones', 'transfer_without_counterparty', 'warn',
 'Toda transferencia trae banco y cuenta de contraparte',
 $q$
 SELECT trans_id, account_id, trans_date, operation, partner_bank, partner_account
 FROM clean.trans
 WHERE operation IN ('transfer_in', 'transfer_out')
   AND (partner_bank IS NULL OR partner_account IS NULL)
 $q$),

-- 7. Saldos ----------------------------------------------------------------
-- El dataset no trae hora, así que el orden de dos movimientos del mismo día
-- es desconocido. Para no reportar falsos errores, las pruebas de saldo solo
-- evalúan los días en que la cuenta tuvo un único movimiento.
--
-- Montos y saldos se publican con un decimal, pero el banco calculaba con más
-- precisión: en movimientos con monto fraccionario (intereses, mensualidades)
-- el saldo puede diferir en 0.1 del esperado. Por eso hay dos pruebas:
--   running_balance_mismatch  (error): diferencia mayor a 0.1 -> falta un
--                                      movimiento o está fuera de orden
--   running_balance_rounding  (warn):  diferencia de hasta 0.1 -> redondeo
('saldos', 'first_trans_not_opening_deposit', 'error',
 'El primer movimiento de cada cuenta es un abono y su saldo es igual al monto',
 $q$
 WITH first_day AS (
     SELECT t.*, count(*) OVER (PARTITION BY t.account_id) AS n
     FROM clean.trans t
     JOIN (SELECT account_id, min(trans_date) AS d
           FROM clean.trans GROUP BY account_id) f
       ON f.account_id = t.account_id AND f.d = t.trans_date
 )
 SELECT trans_id, account_id, trans_date, direction, amount, balance
 FROM first_day
 WHERE n = 1
   AND (direction <> 'credit' OR balance <> amount)
 $q$),

('saldos', 'running_balance_mismatch', 'error',
 'El saldo de cada movimiento es el saldo anterior más o menos el monto (tolerancia 0.1)',
 $q$
 WITH daily AS (
     SELECT account_id, trans_date,
            count(*)      AS n,
            min(trans_id) AS trans_id,
            min(balance)  AS balance,
            sum(CASE direction WHEN 'credit' THEN amount ELSE -amount END) AS net
     FROM clean.trans
     GROUP BY account_id, trans_date
 ),
 seq AS (
     SELECT *,
            lag(n)       OVER w AS prev_n,
            lag(balance) OVER w AS prev_balance
     FROM daily
     WINDOW w AS (PARTITION BY account_id ORDER BY trans_date)
 )
 SELECT trans_id, account_id, trans_date, prev_balance, net, balance,
        balance - (prev_balance + net) AS difference
 FROM seq
 WHERE n = 1 AND prev_n = 1
   AND abs(balance - (prev_balance + net)) > 0.1
 $q$),

('saldos', 'running_balance_rounding', 'warn',
 'El saldo de cada movimiento cuadra exacto, sin diferencias de redondeo',
 $q$
 WITH daily AS (
     SELECT account_id, trans_date,
            count(*)      AS n,
            min(trans_id) AS trans_id,
            min(balance)  AS balance,
            sum(CASE direction WHEN 'credit' THEN amount ELSE -amount END) AS net
     FROM clean.trans
     GROUP BY account_id, trans_date
 ),
 seq AS (
     SELECT *,
            lag(n)       OVER w AS prev_n,
            lag(balance) OVER w AS prev_balance
     FROM daily
     WINDOW w AS (PARTITION BY account_id ORDER BY trans_date)
 )
 SELECT trans_id, account_id, trans_date, prev_balance, net, balance,
        balance - (prev_balance + net) AS difference
 FROM seq
 WHERE n = 1 AND prev_n = 1
   AND abs(balance - (prev_balance + net)) > 0.01
   AND abs(balance - (prev_balance + net)) <= 0.1
 $q$),

('saldos', 'account_with_negative_balance', 'warn',
 'Ninguna cuenta llega a tener saldo negativo',
 $q$
 SELECT account_id, min(balance) AS lowest_balance,
        count(*) FILTER (WHERE balance < 0) AS negative_movements
 FROM clean.trans
 GROUP BY account_id
 HAVING min(balance) < 0
 $q$),

-- 8. Valores faltantes -----------------------------------------------------
('faltantes', 'district_missing_values', 'warn',
 'Los distritos tienen completos sus indicadores de 1995',
 $q$
 SELECT district_id, district_name, unemployment_1995_pct, crimes_1995
 FROM clean.district
 WHERE unemployment_1995_pct IS NULL OR crimes_1995 IS NULL
 $q$);

------------------------------------------------------------------------------
-- Ejecución y reporte
------------------------------------------------------------------------------
CALL quality.run_all();

SELECT category, test_name, severity, failing_rows, status
FROM quality.report
ORDER BY test_id;

SELECT status, count(*) AS tests
FROM quality.report
GROUP BY status
ORDER BY status;