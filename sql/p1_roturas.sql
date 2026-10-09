-- =============================================================================
-- P1. ¿Dónde se rompe el stock y por qué?
-- =============================================================================
-- Base de datos: data/almacen.db
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Situación general: fill rate y roturas del año
-- -----------------------------------------------------------------------------
WITH semana_sku AS (
  -- unidades por semana y SKU, sumando tiendas
  SELECT semana, id_sku,
    SUM(uds_pedidas) AS pedidas,
    SUM(uds_servidas) AS servidas
  FROM fact_pedido_tienda
  GROUP BY semana, id_sku
)
SELECT
  SUM(pedidas) AS uds_pedidas,
  SUM(servidas) AS uds_servidas,
  SUM(pedidas) - SUM(servidas) AS uds_no_servidas,
  ROUND(SUM(servidas) * 100.0 / SUM(pedidas), 2) AS fill_rate,
  COUNT(*) AS combinaciones_semana_sku,
  SUM(servidas < pedidas) AS combinaciones_con_rotura,
  ROUND(SUM(servidas < pedidas) * 100.0 / COUNT(*), 2) AS pct_con_rotura
FROM semana_sku;


-- -----------------------------------------------------------------------------
-- 2. Curva de tallas: fill rate por familia y talla
-- -----------------------------------------------------------------------------
SELECT p.familia, p.talla, p.orden_talla,
  CASE
    WHEN p.familia = 'calzado' AND p.orden_talla IN (4, 5) THEN 'central'
    WHEN p.familia = 'textil' AND p.orden_talla = 3 THEN 'central'
    ELSE 'extrema'
  END AS tipo_talla,
  SUM(f.uds_pedidas) AS uds_pedidas,
  SUM(f.uds_pedidas) - SUM(f.uds_servidas) AS uds_no_servidas,
  ROUND(SUM(f.uds_servidas) * 100.0 / SUM(f.uds_pedidas), 2) AS fill_rate
FROM fact_pedido_tienda f
JOIN dim_producto p ON p.id_sku = f.id_sku
GROUP BY p.familia, p.talla, p.orden_talla
ORDER BY p.familia, p.orden_talla;


-- -----------------------------------------------------------------------------
-- 3. Curva de tallas: tallas centrales frente a extremas, por familia y total
-- -----------------------------------------------------------------------------
WITH talla AS (
  SELECT p.familia,
    CASE
      WHEN p.familia = 'calzado' AND p.orden_talla IN (4, 5) THEN 'central'
      WHEN p.familia = 'textil' AND p.orden_talla = 3 THEN 'central'
      ELSE 'extrema'
    END AS tipo_talla,
    f.uds_pedidas, f.uds_servidas
  FROM fact_pedido_tienda f
  JOIN dim_producto p ON p.id_sku = f.id_sku
),
resumen AS (
  SELECT familia,
    SUM(CASE WHEN tipo_talla = 'central' THEN uds_servidas END) * 100.0
      / SUM(CASE WHEN tipo_talla = 'central' THEN uds_pedidas END) AS fr_central,
    SUM(CASE WHEN tipo_talla = 'extrema' THEN uds_servidas END) * 100.0
      / SUM(CASE WHEN tipo_talla = 'extrema' THEN uds_pedidas END) AS fr_extrema
  FROM talla
  GROUP BY familia
  UNION ALL
  SELECT 'total',
    SUM(CASE WHEN tipo_talla = 'central' THEN uds_servidas END) * 100.0
      / SUM(CASE WHEN tipo_talla = 'central' THEN uds_pedidas END),
    SUM(CASE WHEN tipo_talla = 'extrema' THEN uds_servidas END) * 100.0
      / SUM(CASE WHEN tipo_talla = 'extrema' THEN uds_pedidas END)
  FROM talla
)
SELECT familia,
  ROUND(fr_central, 2) AS fill_rate_central,
  ROUND(fr_extrema, 2) AS fill_rate_extrema,
  ROUND(fr_extrema - fr_central, 2) AS diferencia_puntos
FROM resumen;


-- -----------------------------------------------------------------------------
-- 4. Fill rate y tasa de rotura por proveedor
-- -----------------------------------------------------------------------------
SELECT pr.id_proveedor, pr.familia,
  SUM(f.uds_pedidas) AS uds_pedidas,
  SUM(f.uds_pedidas) - SUM(f.uds_servidas) AS uds_no_servidas,
  ROUND(SUM(f.uds_servidas) * 100.0 / SUM(f.uds_pedidas), 2) AS fill_rate,
  ROUND((SUM(f.uds_pedidas) - SUM(f.uds_servidas)) * 100.0
        / SUM(f.uds_pedidas), 2) AS tasa_rotura
FROM fact_pedido_tienda f
JOIN dim_producto p ON p.id_sku = f.id_sku
JOIN dim_proveedor pr ON pr.id_proveedor = p.id_proveedor
GROUP BY pr.id_proveedor, pr.familia
ORDER BY fill_rate;


-- -----------------------------------------------------------------------------
-- 5. Tasa de rotura de P04 frente al resto de proveedores
-- -----------------------------------------------------------------------------
WITH rotura AS (
  SELECT
    CASE WHEN p.id_proveedor = 'P04' THEN 'P04' ELSE 'resto' END AS grupo,
    (SUM(f.uds_pedidas) - SUM(f.uds_servidas)) * 100.0
      / SUM(f.uds_pedidas) AS tasa_rotura
  FROM fact_pedido_tienda f
  JOIN dim_producto p ON p.id_sku = f.id_sku
  GROUP BY grupo
)
SELECT
  ROUND((SELECT tasa_rotura FROM rotura WHERE grupo = 'P04'), 2) AS tasa_rotura_p04,
  ROUND((SELECT tasa_rotura FROM rotura WHERE grupo = 'resto'), 2) AS tasa_rotura_resto,
  ROUND((SELECT tasa_rotura FROM rotura WHERE grupo = 'P04')
        / (SELECT tasa_rotura FROM rotura WHERE grupo = 'resto'), 2) AS cociente;


-- -----------------------------------------------------------------------------
-- 6. Picos de demanda: fill rate en semanas de pico frente a normales
-- -----------------------------------------------------------------------------
WITH semana_tipo AS (
  SELECT f.semana, f.uds_pedidas, f.uds_servidas,
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM dim_evento_comercial e
        WHERE date(f.semana, '+7 days') BETWEEN e.fecha_inicio AND e.fecha_fin
      ) THEN 'pico'
      ELSE 'normal'
    END AS tipo_semana
  FROM fact_pedido_tienda f
)
SELECT tipo_semana,
  COUNT(DISTINCT semana) AS n_semanas,
  SUM(uds_pedidas) AS uds_pedidas,
  SUM(uds_pedidas) - SUM(uds_servidas) AS uds_no_servidas,
  ROUND(SUM(uds_servidas) * 100.0 / SUM(uds_pedidas), 2) AS fill_rate
FROM semana_tipo
GROUP BY tipo_semana
ORDER BY fill_rate DESC;


-- -----------------------------------------------------------------------------
-- 7. Picos de demanda: detalle por evento comercial
-- -----------------------------------------------------------------------------
SELECT e.id_evento, e.evento,
  COUNT(DISTINCT f.semana) AS n_semanas,
  SUM(f.uds_pedidas) AS uds_pedidas,
  SUM(f.uds_pedidas) - SUM(f.uds_servidas) AS uds_no_servidas,
  ROUND(SUM(f.uds_servidas) * 100.0 / SUM(f.uds_pedidas), 2) AS fill_rate
FROM fact_pedido_tienda f
JOIN dim_evento_comercial e
  ON date(f.semana, '+7 days') BETWEEN e.fecha_inicio AND e.fecha_fin
GROUP BY e.id_evento, e.evento
ORDER BY MIN(f.semana);


-- -----------------------------------------------------------------------------
-- 8. Cumplimiento de proveedores: lo recibido y lo pendiente, por separado
-- -----------------------------------------------------------------------------
WITH recibidas AS (
  SELECT p.id_proveedor,
    COUNT(*) AS lineas_recibidas,
    AVG(julianday(c.fecha_recepcion) - julianday(c.fecha_prevista)) AS retraso_medio_dias,
    SUM(julianday(c.fecha_recepcion) - julianday(c.fecha_prevista) > 7) * 100.0
      / COUNT(*) AS pct_lineas_retraso_7d,
    SUM(c.uds_recibidas) * 100.0 / SUM(c.uds_pedidas) AS pct_uds_recibidas
  FROM fact_compra c
  JOIN dim_producto p ON p.id_sku = c.id_sku
  WHERE c.fecha_recepcion IS NOT NULL
  GROUP BY p.id_proveedor
),
pendientes AS (
  SELECT p.id_proveedor,
    COUNT(*) AS lineas_pendientes,
    SUM(c.uds_pedidas) AS uds_pendientes
  FROM fact_compra c
  JOIN dim_producto p ON p.id_sku = c.id_sku
  WHERE c.fecha_recepcion IS NULL
  GROUP BY p.id_proveedor
)
SELECT pr.id_proveedor, pr.familia,
  pr.lead_time_medio_dias AS plazo_declarado_dias,
  r.lineas_recibidas,
  ROUND(r.retraso_medio_dias, 1) AS retraso_medio_dias,
  ROUND(r.pct_lineas_retraso_7d, 1) AS pct_lineas_retraso_7d,
  ROUND(r.pct_uds_recibidas, 1) AS pct_uds_recibidas,
  COALESCE(pe.lineas_pendientes, 0) AS lineas_pendientes,
  COALESCE(pe.uds_pendientes, 0) AS uds_pendientes
FROM dim_proveedor pr
LEFT JOIN recibidas r ON r.id_proveedor = pr.id_proveedor
LEFT JOIN pendientes pe ON pe.id_proveedor = pr.id_proveedor
ORDER BY pr.id_proveedor;
