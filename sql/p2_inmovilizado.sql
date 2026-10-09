-- =============================================================================
-- P2. ¿Cuánto capital está parado y en qué productos?
-- =============================================================================
-- Base de datos: data/almacen.db
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Evolución semanal: valor del stock y valor inmovilizado
-- -----------------------------------------------------------------------------
WITH servidas AS (
  SELECT id_sku, semana, SUM(uds_servidas) AS servidas
  FROM fact_pedido_tienda
  GROUP BY id_sku, semana
),
ventana AS (
  SELECT s.semana, s.id_sku,
    s.stock_final_uds * p.coste_unitario AS valor,
    SUM(COALESCE(v.servidas, 0)) OVER (
      PARTITION BY s.id_sku ORDER BY s.semana
      ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS servidas_12s
  FROM fact_stock_semanal s
  JOIN dim_producto p ON p.id_sku = s.id_sku
  LEFT JOIN servidas v ON v.id_sku = s.id_sku AND v.semana = s.semana
  WHERE s.semana <> '2024-12-23'
)
SELECT semana,
  ROUND(SUM(valor), 2) AS valor_stock,
  CASE WHEN semana >= '2025-03-17'
    THEN ROUND(SUM(CASE WHEN servidas_12s = 0 THEN valor ELSE 0 END), 2)
  END AS valor_inmovilizado,
  CASE WHEN semana >= '2025-03-17'
    THEN ROUND(SUM(CASE WHEN servidas_12s = 0 THEN valor ELSE 0 END) * 100.0
               / SUM(valor), 2)
  END AS pct_inmovilizado
FROM ventana
GROUP BY semana
ORDER BY semana;


-- -----------------------------------------------------------------------------
-- 2. Porcentaje de valor inmovilizado: resumen de las 41 semanas calculables
-- -----------------------------------------------------------------------------
WITH servidas AS (
  SELECT id_sku, semana, SUM(uds_servidas) AS servidas
  FROM fact_pedido_tienda
  GROUP BY id_sku, semana
),
ventana AS (
  SELECT s.semana,
    s.stock_final_uds * p.coste_unitario AS valor,
    SUM(COALESCE(v.servidas, 0)) OVER (
      PARTITION BY s.id_sku ORDER BY s.semana
      ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS servidas_12s
  FROM fact_stock_semanal s
  JOIN dim_producto p ON p.id_sku = s.id_sku
  LEFT JOIN servidas v ON v.id_sku = s.id_sku AND v.semana = s.semana
  WHERE s.semana <> '2024-12-23'
),
inmovilizado AS (
  SELECT semana,
    SUM(CASE WHEN servidas_12s = 0 THEN valor ELSE 0 END) * 100.0
      / SUM(valor) AS pct_inmovilizado
  FROM ventana
  WHERE semana >= '2025-03-17'
  GROUP BY semana
)
SELECT COUNT(*) AS n_semanas,
  ROUND(AVG(pct_inmovilizado), 2) AS pct_medio,
  ROUND(MIN(pct_inmovilizado), 2) AS pct_minimo,
  ROUND(MAX(pct_inmovilizado), 2) AS pct_maximo
FROM inmovilizado;


-- -----------------------------------------------------------------------------
-- 3. Valor medio del stock y rotación anual, por familia y tipo
-- -----------------------------------------------------------------------------
WITH stock_semanal AS (
  SELECT p.familia, p.tipo, s.semana,
    SUM(s.stock_final_uds * p.coste_unitario) AS valor_semana
  FROM fact_stock_semanal s
  JOIN dim_producto p ON p.id_sku = s.id_sku
  WHERE s.semana <> '2024-12-23'
  GROUP BY p.familia, p.tipo, s.semana
),
stock AS (
  SELECT familia, tipo, AVG(valor_semana) AS valor_medio_stock
  FROM stock_semanal
  GROUP BY familia, tipo
),
consumo AS (
  SELECT p.familia, p.tipo,
    SUM(f.uds_servidas * p.coste_unitario) AS valor_consumido
  FROM fact_pedido_tienda f
  JOIN dim_producto p ON p.id_sku = f.id_sku
  GROUP BY p.familia, p.tipo
),
resultado AS (
  SELECT s.familia, s.tipo, c.valor_consumido, s.valor_medio_stock
  FROM stock s
  JOIN consumo c ON c.familia = s.familia AND c.tipo = s.tipo
  UNION ALL
  SELECT 'total', 'total', SUM(c.valor_consumido), SUM(s.valor_medio_stock)
  FROM stock s
  JOIN consumo c ON c.familia = s.familia AND c.tipo = s.tipo
)
SELECT familia, tipo,
  ROUND(valor_consumido, 2) AS valor_consumido,
  ROUND(valor_medio_stock, 2) AS valor_medio_stock,
  ROUND(valor_consumido / valor_medio_stock, 2) AS rotacion_anual
FROM resultado;


-- -----------------------------------------------------------------------------
-- 4. Foto de cierre: valor del stock e inmovilizado por temporada
-- -----------------------------------------------------------------------------
WITH con_salida AS (
  SELECT DISTINCT id_sku
  FROM fact_pedido_tienda
  WHERE semana BETWEEN '2025-10-06' AND '2025-12-22'
    AND uds_servidas > 0
),
cierre AS (
  SELECT p.temporada,
    s.stock_final_uds * p.coste_unitario AS valor,
    CASE WHEN c.id_sku IS NULL THEN 1 ELSE 0 END AS inmovilizado
  FROM fact_stock_semanal s
  JOIN dim_producto p ON p.id_sku = s.id_sku
  LEFT JOIN con_salida c ON c.id_sku = s.id_sku
  WHERE s.semana = '2025-12-22' AND s.stock_final_uds > 0
),
resultado AS (
  SELECT temporada,
    COUNT(*) AS n_sku_con_stock,
    SUM(inmovilizado) AS n_sku_inmovilizados,
    SUM(valor) AS valor_stock,
    SUM(valor * inmovilizado) AS valor_inmovilizado
  FROM cierre
  GROUP BY temporada
  UNION ALL
  SELECT 'total', COUNT(*), SUM(inmovilizado), SUM(valor), SUM(valor * inmovilizado)
  FROM cierre
)
SELECT temporada, n_sku_con_stock, n_sku_inmovilizados,
  ROUND(valor_stock, 2) AS valor_stock,
  ROUND(valor_inmovilizado, 2) AS valor_inmovilizado,
  ROUND(valor_inmovilizado * 100.0 / valor_stock, 2) AS pct_inmovilizado
FROM resultado;


-- -----------------------------------------------------------------------------
-- 5. Aging por tramos, a fecha de cierre
-- -----------------------------------------------------------------------------
WITH ultima_venta AS (
  SELECT id_sku, MAX(semana) AS ultima_semana
  FROM fact_pedido_tienda
  WHERE uds_servidas > 0
  GROUP BY id_sku
),
aging AS (
  SELECT s.id_sku,
    s.stock_final_uds * p.coste_unitario AS valor_stock,
    (julianday('2025-12-22') - julianday(u.ultima_semana)) / 7 AS semanas_aging
  FROM fact_stock_semanal s
  JOIN dim_producto p ON p.id_sku = s.id_sku
  LEFT JOIN ultima_venta u ON u.id_sku = s.id_sku
  WHERE s.semana = '2025-12-22' AND s.stock_final_uds > 0
)
SELECT
  CASE
    WHEN semanas_aging IS NULL THEN 'sin ventas'
    WHEN semanas_aging <= 3 THEN '0-3'
    WHEN semanas_aging <= 11 THEN '4-11'
    WHEN semanas_aging <= 25 THEN '12-25'
    ELSE '26 o más'
  END AS tramo_aging,
  COUNT(*) AS n_sku,
  ROUND(SUM(valor_stock), 2) AS valor_stock,
  ROUND(SUM(valor_stock) * 100.0 / (SELECT SUM(valor_stock) FROM aging), 2) AS pct_valor
FROM aging
GROUP BY tramo_aging
ORDER BY MIN(COALESCE(semanas_aging, 999));


-- -----------------------------------------------------------------------------
-- 6. Cobertura por tramos, a fecha de cierre
-- -----------------------------------------------------------------------------
WITH demanda AS (
  SELECT id_sku, SUM(uds_pedidas) / 4.0 AS demanda_media_semanal
  FROM fact_pedido_tienda
  WHERE semana BETWEEN '2025-12-01' AND '2025-12-22'
  GROUP BY id_sku
),
cobertura AS (
  SELECT s.id_sku,
    s.stock_final_uds * p.coste_unitario AS valor_stock,
    s.stock_final_uds / d.demanda_media_semanal AS semanas_cobertura
  FROM fact_stock_semanal s
  JOIN dim_producto p ON p.id_sku = s.id_sku
  LEFT JOIN demanda d ON d.id_sku = s.id_sku
  WHERE s.semana = '2025-12-22' AND s.stock_final_uds > 0
)
SELECT
  CASE
    WHEN semanas_cobertura IS NULL THEN 'sin demanda'
    WHEN semanas_cobertura < 4 THEN 'menos de 4'
    WHEN semanas_cobertura < 12 THEN '4-11'
    WHEN semanas_cobertura < 26 THEN '12-25'
    ELSE '26 o más'
  END AS tramo_cobertura,
  COUNT(*) AS n_sku,
  ROUND(SUM(valor_stock), 2) AS valor_stock,
  ROUND(SUM(valor_stock) * 100.0 / (SELECT SUM(valor_stock) FROM cobertura), 2) AS pct_valor
FROM cobertura
GROUP BY tramo_cobertura
ORDER BY MIN(COALESCE(semanas_cobertura, 9999));


-- -----------------------------------------------------------------------------
-- 7. Los 10 modelos con más valor inmovilizado a fecha de cierre
-- -----------------------------------------------------------------------------
WITH ultima_venta AS (
  SELECT id_sku, MAX(semana) AS ultima_semana
  FROM fact_pedido_tienda
  WHERE uds_servidas > 0
  GROUP BY id_sku
),
inmovilizado AS (
  SELECT p.id_modelo, p.familia, p.subfamilia, p.tipo, p.temporada,
    s.stock_final_uds,
    s.stock_final_uds * p.coste_unitario AS valor,
    u.ultima_semana
  FROM fact_stock_semanal s
  JOIN dim_producto p ON p.id_sku = s.id_sku
  LEFT JOIN ultima_venta u ON u.id_sku = s.id_sku
  WHERE s.semana = '2025-12-22'
    AND s.stock_final_uds > 0
    AND (u.ultima_semana IS NULL OR u.ultima_semana < '2025-10-06')
)
SELECT id_modelo, familia, subfamilia, tipo, temporada,
  COUNT(*) AS n_sku,
  SUM(stock_final_uds) AS uds_stock,
  ROUND(SUM(valor), 2) AS valor_inmovilizado,
  COALESCE(MAX(ultima_semana), 'sin ventas') AS ultima_salida
FROM inmovilizado
GROUP BY id_modelo, familia, subfamilia, tipo, temporada
ORDER BY valor_inmovilizado DESC
LIMIT 10;
