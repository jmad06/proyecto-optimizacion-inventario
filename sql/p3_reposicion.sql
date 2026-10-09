-- =============================================================================
-- P3. ¿Qué punto de pedido y stock de seguridad corresponde a cada segmento
--     del surtido, y qué ahorro supone frente a la política actual?
-- =============================================================================
-- Base de datos: data/almacen.db
-- =============================================================================


-- =============================================================================
-- 1. Clasificación ABC: resumen por clase
-- =============================================================================
SELECT clase_abc,
  COUNT(*) AS n_sku,
  ROUND(SUM(valor), 2) AS valor_consumido,
  ROUND(SUM(pct), 1) AS pct_valor
FROM v_abc
GROUP BY clase_abc
ORDER BY clase_abc;


-- =============================================================================
-- 2. Clasificación XYZ por tipo de producto
-- =============================================================================
SELECT p.tipo,
  SUM(x.clase_xyz = 'X') AS x,
  SUM(x.clase_xyz = 'Y') AS y,
  SUM(x.clase_xyz = 'Z') AS z,
  SUM(x.id_sku IS NULL) AS sin_demanda
FROM dim_producto p
LEFT JOIN v_xyz x ON x.id_sku = p.id_sku
GROUP BY p.tipo;


-- =============================================================================
-- 3. Matriz ABC/XYZ: referencias y valor consumido por segmento
-- =============================================================================
SELECT clase_abc, clase_xyz,
  COUNT(*) AS n_sku,
  ROUND(SUM(a.valor), 2) AS valor_consumido,
  ROUND(SUM(a.pct), 1) AS pct_valor
FROM v_politica_sku s
JOIN v_abc a USING (id_sku, clase_abc)
GROUP BY clase_abc, clase_xyz
ORDER BY clase_abc, clase_xyz;


-- =============================================================================
-- 4. Plazos de entrega: declarado, observado y el que se usa
-- =============================================================================
SELECT id_proveedor,
  lt_decl_dias,
  ROUND(lt_obs_dias, 1) AS lt_obs_dias,
  ROUND(lt_dias, 1) AS lt_usado_dias,
  desv_decl_dias,
  ROUND(desv_obs_dias, 1) AS desv_obs_dias,
  desv_dias AS desv_usada_dias,
  origen_plazo
FROM v_plazo
ORDER BY id_proveedor;


-- =============================================================================
-- 5. Stock de seguridad y punto de pedido por clase ABC
-- =============================================================================
SELECT clase_abc,
  COUNT(ss) AS n_sku_con_demanda,
  ROUND(AVG(ss), 2) AS ss_medio_uds,
  ROUND(SUM(ss * coste_unitario), 2) AS valor_ss,
  ROUND(AVG(rop), 2) AS rop_medio_uds,
  ROUND(SUM(rop * coste_unitario), 2) AS valor_rop
FROM v_politica_sku
GROUP BY clase_abc
ORDER BY clase_abc;


-- =============================================================================
-- 6. Política de reposición por segmento
-- =============================================================================
SELECT s.clase_abc, s.clase_xyz,
  COUNT(*) AS n_sku,
  ROUND(AVG(s.d), 2) AS demanda_media_semanal,
  ROUND(AVG(s.ss), 2) AS ss_medio_uds,
  ROUND(AVG(s.rop), 2) AS rop_medio_uds,
  ROUND(SUM(s.stock_medio * s.coste_unitario), 0) AS valor_actual,
  ROUND(SUM(s.objetivo_medio * s.coste_unitario), 0) AS valor_objetivo,
  ROUND(SUM((s.stock_medio - s.objetivo_medio) * s.coste_unitario)
        * par.coste_posesion, 0) AS ahorro_anual
FROM v_politica_sku s
CROSS JOIN v_parametros par
GROUP BY s.clase_abc, s.clase_xyz
ORDER BY ahorro_anual DESC;


-- =============================================================================
-- 7. Ahorro anual estimado: totales
-- =============================================================================
SELECT
  ROUND(SUM(s.stock_medio * s.coste_unitario), 0) AS valor_stock_medio_actual,
  ROUND(SUM(s.objetivo_medio * s.coste_unitario), 0) AS valor_stock_objetivo,
  ROUND(SUM((s.stock_medio - s.objetivo_medio) * s.coste_unitario), 0) AS reduccion_stock,
  ROUND(SUM((s.stock_medio - s.objetivo_medio) * s.coste_unitario)
        * par.coste_posesion, 0) AS ahorro_anual,
  ROUND(SUM(CASE WHEN s.d IS NULL THEN s.stock_medio * s.coste_unitario END)
        * par.coste_posesion, 0) AS ahorro_de_sku_sin_demanda
FROM v_politica_sku s
CROSS JOIN v_parametros par;


-- =============================================================================
-- 8. Rotura inminente a fecha de cierre: SKU de clase A y B bajo su punto de
--    pedido, con demanda en las 4 últimas semanas
-- =============================================================================
WITH demanda_dic AS (
  SELECT id_sku
  FROM fact_pedido_tienda
  WHERE semana BETWEEN '2025-12-01' AND '2025-12-22'
  GROUP BY id_sku
  HAVING SUM(uds_pedidas) > 0
)
SELECT s.clase_abc,
  COUNT(*) AS n_sku_bajo_rop,
  ROUND(SUM((s.rop - st.stock_final_uds) * s.coste_unitario), 2) AS deficit_valor
FROM v_politica_sku s
JOIN demanda_dic dd ON dd.id_sku = s.id_sku
JOIN fact_stock_semanal st
  ON st.id_sku = s.id_sku AND st.semana = '2025-12-22'
WHERE s.clase_abc IN ('A', 'B')
  AND st.stock_final_uds < s.rop
GROUP BY s.clase_abc
ORDER BY s.clase_abc;


-- =============================================================================
-- 9. Venta perdida actual
-- =============================================================================
WITH semanas_rebajas AS (
  SELECT DISTINCT f.semana
  FROM fact_pedido_tienda f
  JOIN dim_evento_comercial e
    ON date(f.semana, '+7 days') BETWEEN e.fecha_inicio AND e.fecha_fin
  WHERE e.evento IN ('rebajas_invierno', 'rebajas_verano')
),
perdida AS (
  SELECT p.familia,
    (f.uds_pedidas - f.uds_servidas)
      * CASE WHEN r.semana IS NOT NULL
             THEN p.pvp * (1 - par.descuento_rebajas) - p.coste_unitario
             ELSE p.pvp - p.coste_unitario END AS margen_perdido
  FROM fact_pedido_tienda f
  JOIN dim_producto p ON p.id_sku = f.id_sku
  CROSS JOIN v_parametros par
  LEFT JOIN semanas_rebajas r ON r.semana = f.semana
)
SELECT familia, ROUND(SUM(margen_perdido), 0) AS venta_perdida
FROM perdida
GROUP BY familia
UNION ALL
SELECT 'total', ROUND(SUM(margen_perdido), 0)
FROM perdida;


-- =============================================================================
-- 10. Incremento de demanda por evento (cuánto stock anticipar antes de cada pico)
-- =============================================================================
WITH demanda_semana AS (
  SELECT p.tipo, f.semana, SUM(f.uds_pedidas) AS uds
  FROM fact_pedido_tienda f
  JOIN dim_producto p ON p.id_sku = f.id_sku
  GROUP BY p.tipo, f.semana
),
semana_evento AS (
  SELECT d.tipo, d.semana, d.uds, e.evento
  FROM demanda_semana d
  LEFT JOIN dim_evento_comercial e
    ON date(d.semana, '+7 days') BETWEEN e.fecha_inicio AND e.fecha_fin
),
normal AS (
  SELECT tipo, AVG(uds) AS media_normal
  FROM semana_evento
  WHERE evento IS NULL
  GROUP BY tipo
)
SELECT s.tipo, s.evento,
  COUNT(*) AS n_semanas,
  ROUND(AVG(s.uds) / n.media_normal, 2) AS incremento
FROM semana_evento s
JOIN normal n ON n.tipo = s.tipo
WHERE s.evento IS NOT NULL
GROUP BY s.tipo, s.evento
ORDER BY s.tipo, incremento DESC;
