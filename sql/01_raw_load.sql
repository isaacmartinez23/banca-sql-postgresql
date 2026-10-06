-- 01_raw_load.sql
-- Carga cruda del dataset Berka (PKDD'99) en el esquema raw.
-- Todas las columnas entran como TEXT a propósito: las fechas vienen como
-- YYMMDD y hay valores faltantes marcados con '?', así que la conversión de
-- tipos se hace después, en la capa limpia. Aquí solo se copia tal cual.
--
-- Requisitos: los 8 archivos en ./data (visible en el contenedor como /data).
-- Ejecutar desde psql:  \i /docker-entrypoint-initdb.d/01_raw_load.sql

CREATE SCHEMA IF NOT EXISTS raw;

DROP TABLE IF EXISTS raw.account, raw.client, raw.disp, raw.orders,
                     raw.trans, raw.loan, raw.card, raw.district;

CREATE TABLE raw.account (
    account_id  text,
    district_id text,
    frequency   text,
    date        text
);

CREATE TABLE raw.client (
    client_id    text,
    birth_number text,
    district_id  text
);

CREATE TABLE raw.disp (
    disp_id    text,
    client_id  text,
    account_id text,
    type       text
);

-- "order" es palabra reservada en SQL, por eso la tabla se llama orders
CREATE TABLE raw.orders (
    order_id   text,
    account_id text,
    bank_to    text,
    account_to text,
    amount     text,
    k_symbol   text
);

CREATE TABLE raw.trans (
    trans_id   text,
    account_id text,
    date       text,
    type       text,
    operation  text,
    amount     text,
    balance    text,
    k_symbol   text,
    bank       text,
    account    text
);

CREATE TABLE raw.loan (
    loan_id    text,
    account_id text,
    date       text,
    amount     text,
    duration   text,
    payments   text,
    status     text
);

CREATE TABLE raw.card (
    card_id text,
    disp_id text,
    type    text,
    issued  text
);

CREATE TABLE raw.district (
    a1  text, a2  text, a3  text, a4  text,
    a5  text, a6  text, a7  text, a8  text,
    a9  text, a10 text, a11 text, a12 text,
    a13 text, a14 text, a15 text, a16 text
);

-- Carga. Los archivos originales usan ';' como separador y traen encabezado.
COPY raw.account  FROM '/data/account.csv'  WITH (FORMAT csv, DELIMITER ';', HEADER true);
COPY raw.client   FROM '/data/client.csv'   WITH (FORMAT csv, DELIMITER ';', HEADER true);
COPY raw.disp     FROM '/data/disp.csv'     WITH (FORMAT csv, DELIMITER ';', HEADER true);
COPY raw.orders  FROM '/data/order.csv'   WITH (FORMAT csv, DELIMITER ';', HEADER true);
COPY raw.trans    FROM '/data/trans.csv'    WITH (FORMAT csv, DELIMITER ';', HEADER true);
COPY raw.loan     FROM '/data/loan.csv'     WITH (FORMAT csv, DELIMITER ';', HEADER true);
COPY raw.card     FROM '/data/card.csv'     WITH (FORMAT csv, DELIMITER ';', HEADER true);
COPY raw.district FROM '/data/district.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true);

-- Verificación: conteo por tabla contra lo publicado del dataset
SELECT 'account'  AS tabla, count(*) AS filas, 4500    AS esperado FROM raw.account
UNION ALL SELECT 'client',   count(*), 5369    FROM raw.client
UNION ALL SELECT 'disp',     count(*), 5369    FROM raw.disp
UNION ALL SELECT 'order',   count(*), 6471    FROM raw.orders
UNION ALL SELECT 'trans',    count(*), 1056320 FROM raw.trans
UNION ALL SELECT 'loan',     count(*), 682     FROM raw.loan
UNION ALL SELECT 'card',     count(*), 892     FROM raw.card
UNION ALL SELECT 'district', count(*), 77      FROM raw.district;