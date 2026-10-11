# Modelo de datos y medidas DAX

Detalle técnico del informe de Power BI. Resumen en el [README](../README.md); hallazgos por página y su razonamiento en [hallazgos.md](hallazgos.md).

## 1. Origen de los datos

Datos generados con una simulación semanal de un almacén central de calzado y textil (semilla fija, reproducible) y validados con reglas de integridad. Solo se guardan datos crudos: todo lo derivado se calcula en SQL o en DAX.

- **Periodo:** semanas ISO 2025-W01 a W52 (del 30/12/2024 al 28/12/2025), más una foto de stock inicial el 23/12/2024. El identificador de semana es el lunes.
- **Surtido:** 92 modelos y 598 referencias (SKU), 5 proveedores y 6 tiendas.
- **Formatos:** base SQLite (`data/almacen.db`) y CSV en `data/csv/`. Power BI importa los CSV.

## 2. Modelo de datos

| Tabla | Filas | Grano | Campos principales |
|---|---|---|---|
| `dim_producto` | 598 | Una por SKU | `id_sku`, `id_modelo`, `familia`, `subfamilia`, `talla`, `orden_talla`, `tipo`, `temporada`, `id_proveedor`, `coste_unitario`, `pvp` |
| `dim_proveedor` | 5 | Una por proveedor | `id_proveedor`, `nombre`, `familia`, `lead_time_medio_dias`, `lead_time_desv_dias`, `pedido_minimo_uds` |
| `dim_tienda` | 6 | Una por tienda | `id_tienda`, `nombre`, `municipio`, `factor_tamano` |
| `dim_evento_comercial` | 5 | Un evento, con fechas de tienda | `id_evento`, `evento`, `fecha_inicio`, `fecha_fin` |
| `fact_pedido_tienda` | 55.898 | Semana, tienda y SKU | `semana`, `id_tienda`, `id_sku`, `uds_pedidas`, `uds_servidas` |
| `fact_stock_semanal` | 31.694 | Semana y SKU (incluye ceros) | `semana`, `id_sku`, `stock_final_uds` |
| `fact_compra` | 2.756 | Línea de pedido de compra | `id_pedido_compra`, `id_sku`, `fecha_pedido`, `fecha_prevista`, `fecha_recepcion`, `uds_pedidas`, `uds_recibidas` |
| `Calendario` | 371 | Un día | Tabla calculada en DAX (apartado 4.1) |

`dim_fecha` existe en los CSV y en SQLite como referencia para las consultas SQL, pero no se importa: el calendario de Power BI se crea en DAX.

## 3. Relaciones

Todas de uno a varios, con dirección de filtro única.

| Desde (uno) | Hacia (varios) |
|---|---|
| `dim_proveedor[id_proveedor]` | `dim_producto[id_proveedor]` |
| `dim_producto[id_sku]` | `fact_pedido_tienda[id_sku]` |
| `dim_producto[id_sku]` | `fact_stock_semanal[id_sku]` |
| `dim_producto[id_sku]` | `fact_compra[id_sku]` |
| `dim_tienda[id_tienda]` | `fact_pedido_tienda[id_tienda]` |
| `Calendario[Fecha]` | `fact_pedido_tienda[semana]` |
| `Calendario[Fecha]` | `fact_stock_semanal[semana]` |
| `dim_evento_comercial[evento]` | `Calendario[EventoAlmacen]` (opcional: ninguna medida la necesita) |

`Calendario` es diario y las tablas de hechos guardan el lunes de cada semana, así que solo casan las filas que son lunes. `fact_compra` no se relaciona con el calendario: llega al proveedor a través de `dim_producto`.

## 4. DAX

Las columnas calculadas se crean en el orden de este documento: algunas usan otras anteriores. Las que necesitan datos de otra tabla usan `FILTER` con el identificador en una variable, en lugar de `CALCULATE`, para evitar dependencias circulares.

### 4.1. Calendario

```dax
Calendario =
VAR Base =
    SELECTCOLUMNS ( CALENDAR ( DATE ( 2024, 12, 23 ), DATE ( 2025, 12, 28 ) ), "Fecha", [Date] )
RETURN
    ADDCOLUMNS (
        Base,
        "SemanaLunes", [Fecha] - WEEKDAY ( [Fecha], 2 ) + 1,
        "IndiceSemana", INT ( DATEDIFF ( DATE ( 2024, 12, 23 ), [Fecha], DAY ) / 7 )
    )
```

- `SemanaLunes`: el lunes de cada semana. Es el eje de los gráficos semanales.
- `IndiceSemana`: 0 es la foto inicial (23/12/2024) y de 1 a 52 las semanas del periodo.

Marcada como tabla de fechas por `Fecha`. Tres columnas calculadas:

**`EventoAlmacen`.** Evento comercial de cada semana, con fechas de almacén (una semana antes que la tienda).

```dax
EventoAlmacen =
VAR FechaTienda = Calendario[SemanaLunes] + 7
VAR Evento =
    MAXX (
        FILTER (
            dim_evento_comercial,
            dim_evento_comercial[fecha_inicio] <= FechaTienda
                && dim_evento_comercial[fecha_fin] >= FechaTienda
        ),
        dim_evento_comercial[evento]
    )
RETURN
    COALESCE ( Evento, "semana normal" )
```

**`TipoSemana`.**

```dax
TipoSemana = IF ( Calendario[EventoAlmacen] = "semana normal", "normal", "pico" )
```

**`MultEvento`.** Multiplicador de demanda de cada semana.

```dax
MultEvento =
SWITCH (
    Calendario[EventoAlmacen],
    "black_friday", 1.6,
    "navidad", 1.8,
    "reyes", 1.5,
    "rebajas_invierno", 1.4,
    "rebajas_verano", 1.4,
    1
)
```

### 4.2. Columnas calculadas de `dim_proveedor`

**`LTUsadoDias`.** Plazo de entrega que usa la política: para P04, el plazo medio observado en los pedidos recibidos (51,2 días frente a 35 declarados); para el resto, el declarado. La desviación usada es siempre la declarada.

```dax
LTUsadoDias =
VAR Proveedor = dim_proveedor[id_proveedor]
VAR Observado =
    AVERAGEX (
        FILTER (
            fact_compra,
            NOT ISBLANK ( fact_compra[fecha_recepcion] )
                && RELATED ( dim_producto[id_proveedor] ) = Proveedor
        ),
        DATEDIFF ( fact_compra[fecha_pedido], fact_compra[fecha_recepcion], DAY )
    )
RETURN
    -- Decisión del proyecto: P04 entrega tarde (página 1, apartado 1.3), así que se usa
    -- su plazo real en vez del declarado; el resto de proveedores usa el declarado
    IF ( Proveedor = "P04", Observado, dim_proveedor[lead_time_medio_dias] )
```

### 4.3. Columnas calculadas de `dim_producto`

#### Talla y clasificación ABC

**`TipoTalla`.** Central (orden 4 y 5 en calzado, 3 en textil) o extrema.

```dax
TipoTalla =
IF (
    ( dim_producto[familia] = "calzado" && dim_producto[orden_talla] IN { 4, 5 } )
        || ( dim_producto[familia] = "textil" && dim_producto[orden_talla] = 3 ),
    "central",
    "extrema"
)
```

**`ValorConsumido`.** Unidades servidas en el año por coste.

```dax
ValorConsumido =
VAR Sku = dim_producto[id_sku]
RETURN
    dim_producto[coste_unitario]
        * SUMX (
            FILTER ( fact_pedido_tienda, fact_pedido_tienda[id_sku] = Sku ),
            fact_pedido_tienda[uds_servidas]
        ) + 0
```

**`ClaseABC`.** Por valor consumido acumulado: A hasta el 80%, B hasta el 95% y C el resto. `id_sku` desempata.

```dax
ClaseABC =
VAR Valor = dim_producto[ValorConsumido]
VAR Sku = dim_producto[id_sku]
VAR Acumulado =
    SUMX (
        FILTER (
            dim_producto,
            dim_producto[ValorConsumido] > Valor
                || ( dim_producto[ValorConsumido] = Valor && dim_producto[id_sku] <= Sku )
        ),
        dim_producto[ValorConsumido]
    )
VAR PctAcumulado = DIVIDE ( Acumulado, SUM ( dim_producto[ValorConsumido] ) )
RETURN
    -- Clasificación ABC por valor acumulado (Silver, Pyke y Thomas, 2017)
    -- A: primer 80% del valor; B: siguiente 15%; C: 5% restante
    SWITCH ( TRUE (), PctAcumulado <= 0.80, "A", PctAcumulado <= 0.95, "B", "C" )
```

#### Demanda y clasificación XYZ

La demanda es la suma de todas las tiendas por SKU y semana, dentro de la ventana de venta del SKU (de su primera a su última semana con pedidos) y sin contar las semanas de evento.

**`DemandaMedia`.** Unidades pedidas por semana.

```dax
DemandaMedia =
VAR Sku = dim_producto[id_sku]
VAR Filas = FILTER ( fact_pedido_tienda, fact_pedido_tienda[id_sku] = Sku )
VAR Primera = MINX ( Filas, fact_pedido_tienda[semana] )
VAR Ultima = MAXX ( Filas, fact_pedido_tienda[semana] )
VAR Semanas =
    FILTER (
        Calendario,
        Calendario[Fecha] = Calendario[SemanaLunes]
            && Calendario[Fecha] >= Primera
            && Calendario[Fecha] <= Ultima
            && Calendario[TipoSemana] = "normal"
    )
VAR Demanda =
    ADDCOLUMNS (
        Semanas,
        "@uds",
            SUMX (
                FILTER ( Filas, fact_pedido_tienda[semana] = Calendario[Fecha] ),
                fact_pedido_tienda[uds_pedidas]
            ) + 0
    )
RETURN
    IF ( NOT ISBLANK ( Primera ), AVERAGEX ( Demanda, [@uds] ) )
```

**`VarianzaDemanda`.** Varianza de esas mismas semanas.

```dax
VarianzaDemanda =
VAR Sku = dim_producto[id_sku]
VAR Filas = FILTER ( fact_pedido_tienda, fact_pedido_tienda[id_sku] = Sku )
VAR Primera = MINX ( Filas, fact_pedido_tienda[semana] )
VAR Ultima = MAXX ( Filas, fact_pedido_tienda[semana] )
VAR Semanas =
    FILTER (
        Calendario,
        Calendario[Fecha] = Calendario[SemanaLunes]
            && Calendario[Fecha] >= Primera
            && Calendario[Fecha] <= Ultima
            && Calendario[TipoSemana] = "normal"
    )
VAR Demanda =
    ADDCOLUMNS (
        Semanas,
        "@uds",
            SUMX (
                FILTER ( Filas, fact_pedido_tienda[semana] = Calendario[Fecha] ),
                fact_pedido_tienda[uds_pedidas]
            ) + 0
    )
RETURN
    IF (
        NOT ISBLANK ( Primera ),
        AVERAGEX ( Demanda, [@uds] ^ 2 ) - AVERAGEX ( Demanda, [@uds] ) ^ 2
    )
```

**`ClaseXYZ`.** Por coeficiente de variación (CV): X estable (menor de 0,5), Y variable (hasta 1), Z errática (mayor de 1). Se compara el CV al cuadrado.

```dax
ClaseXYZ =
VAR D = dim_producto[DemandaMedia]
-- Coeficiente de variación al cuadrado: varianza / media² (evita la raíz)
VAR CV2 = DIVIDE ( dim_producto[VarianzaDemanda], D * D )
RETURN
    -- Clasificación XYZ (Scholz-Reiter et al., 2012). Umbrales habituales, no de una fuente concreta:
    -- CV < 0,5 → X (estable); CV hasta 1 → Y (variable); CV > 1 → Z (errática)
    SWITCH ( TRUE (), ISBLANK ( D ), "Sin demanda", CV2 < 0.25, "X", CV2 <= 1, "Y", "Z" )
```

#### Política de reposición

Nivel de servicio por clase ABC: A al 95% (z = 1,65), B al 90% (z = 1,28), C al 85% (z = 1,04).

**`StockSeguridad`.** z × √(LT × varianza + demanda² × σLT²), con plazo y desviación en semanas.

```dax
StockSeguridad =
VAR D = dim_producto[DemandaMedia]
-- z del nivel de servicio de ciclo (CSL) de cada clase, redondeado a dos decimales
-- (A 95%, B 90%, C 85%; los niveles son hipótesis del proyecto)
VAR Z = SWITCH ( dim_producto[ClaseABC], "A", 1.65, "B", 1.28, 1.04 )
VAR LT = RELATED ( dim_proveedor[LTUsadoDias] ) / 7               -- plazo en semanas
VAR SigmaLT = RELATED ( dim_proveedor[lead_time_desv_dias] ) / 7  -- desviación del plazo en semanas
RETURN
    IF (
        NOT ISBLANK ( D ),
        -- Chopra y Meindl, capítulo de stock de seguridad, caso de plazo variable:
        -- ss = z × σL, con σL = √( L × σD² + D² × sL² )
        -- El primer término recoge la variación de la demanda; el segundo, la del plazo
        Z * SQRT ( LT * dim_producto[VarianzaDemanda] + D ^ 2 * SigmaLT ^ 2 )
    )
```

**`PuntoPedido`.** Demanda durante el plazo más stock de seguridad.

```dax
PuntoPedido =
VAR D = dim_producto[DemandaMedia]
VAR LT = RELATED ( dim_proveedor[LTUsadoDias] ) / 7
RETURN
    -- Chopra y Meindl: ROP = D × L + ss
    -- Demanda esperada hasta que llega el pedido más el colchón para imprevistos
    IF ( NOT ISBLANK ( D ), D * LT + dim_producto[StockSeguridad] )
```

**`StockObjetivoMedio`.** Stock de seguridad más medio pedido de 4 semanas, ponderado por las semanas de la ventana de venta sobre 52. Sin demanda, 0.

```dax
StockObjetivoMedio =
VAR Sku = dim_producto[id_sku]
VAR D = dim_producto[DemandaMedia]
VAR Filas = FILTER ( fact_pedido_tienda, fact_pedido_tienda[id_sku] = Sku )
VAR SemanasVentana =
    DATEDIFF (
        MINX ( Filas, fact_pedido_tienda[semana] ),
        MAXX ( Filas, fact_pedido_tienda[semana] ),
        DAY
    ) / 7 + 1
RETURN
    IF (
        ISBLANK ( D ),
        0,  -- sin demanda, no necesita stock
        -- Chopra y Meindl: inventario medio = Q / 2 + ss, con Q = pedido de 4 semanas (4 × D)
        -- Decisión del proyecto: se pondera por las semanas de venta sobre 52,
        -- porque un producto de temporada solo necesita stock mientras se vende
        ( dim_producto[StockSeguridad] + 4 * D / 2 ) * SemanasVentana / 52
    )
```

#### Antigüedad del stock

**`UltimaSalida`.** Última semana con unidades servidas.

```dax
UltimaSalida =
VAR Sku = dim_producto[id_sku]
RETURN
    MAXX (
        FILTER (
            fact_pedido_tienda,
            fact_pedido_tienda[id_sku] = Sku && fact_pedido_tienda[uds_servidas] > 0
        ),
        fact_pedido_tienda[semana]
    )
```

**`TramoAging`.** Semanas desde la última salida hasta el cierre, en tramos.

```dax
TramoAging =
VAR Ultima = dim_producto[UltimaSalida]
VAR Aging =
    IF (
        NOT ISBLANK ( Ultima ),
        DATEDIFF ( Ultima, MAX ( fact_stock_semanal[semana] ), DAY ) / 7
    )
RETURN
    SWITCH (
        TRUE (),
        ISBLANK ( Ultima ), "sin ventas",
        Aging <= 3, "0-3",
        Aging <= 11, "4-11",
        Aging <= 25, "12-25",
        "26 o más"
    )
```

**`OrdenTramoAging`.** Orden de los tramos en el gráfico. Se calcula sin usar `TramoAging` para evitar una dependencia circular al ordenar.

```dax
OrdenTramoAging =
VAR Ultima = dim_producto[UltimaSalida]
VAR Aging =
    IF (
        NOT ISBLANK ( Ultima ),
        DATEDIFF ( Ultima, MAX ( fact_stock_semanal[semana] ), DAY ) / 7
    )
RETURN
    SWITCH (
        TRUE (),
        ISBLANK ( Ultima ), 5,
        Aging <= 3, 1,
        Aging <= 11, 2,
        Aging <= 25, 3,
        4
    )
```

#### Datos de la recomendación (página 4)

**`PlazoSemanas`.** Plazo de entrega en semanas completas.

```dax
PlazoSemanas = ROUNDUP ( RELATED ( dim_proveedor[LTUsadoDias] ) / 7, 0 )
```

**`InicioTemporada`.** Primer lunes de venta. PV24 queda en blanco (sin ventana).

```dax
InicioTemporada =
SWITCH (
    dim_producto[temporada],
    "CONT", DATE ( 2024, 12, 30 ),
    "OI24", DATE ( 2024, 12, 30 ),
    "PV25", DATE ( 2025, 1, 27 ),
    "OI25", DATE ( 2025, 7, 28 )
)
```

**`FinTemporada`.** Último lunes de venta. Básicos y PV24 quedan en blanco. El de OI25 es una estimación: los datos acaban el 22/12 y la temporada llega hasta finales de enero.

```dax
FinTemporada =
SWITCH (
    dim_producto[temporada],
    "OI24", DATE ( 2025, 1, 26 ),
    "PV25", DATE ( 2025, 7, 27 ),
    "OI25", DATE ( 2026, 2, 1 )
)
```

**`Reponible`.** Falso para los restos (PV24 y OI24): no se les pide nunca.

```dax
Reponible = NOT ( dim_producto[temporada] IN { "PV24", "OI24" } )
```

### 4.4. Parámetros

Dos parámetros de tipo intervalo numérico, con segmentación. Cada uno crea una tabla propia y una medida que lee el valor elegido.

**Descuento medio en rebajas** (0 a 50%, por defecto 30%). Solo lo usa `Venta Perdida`.

```dax
Descuento Seleccionado = SELECTEDVALUE ( 'Descuento Rebajas'[Descuento Rebajas], 0.3 )
```

**Coste de posesión** (5 a 40%, por defecto 20%). Solo lo usa `Ahorro Anual`.

```dax
Coste Posesion Seleccionado = SELECTEDVALUE ( 'Coste Posesion'[Coste Posesion], 0.2 )
```

### 4.5. Medidas

Viven en una tabla vacía `Medidas`, en carpetas por página. Cuando una medida usa otra (entre corchetes), esa se define antes.

#### Página 1: roturas (8)

**`Uds Pedidas`** y **`Uds Servidas`.**

```dax
Uds Pedidas = SUM ( fact_pedido_tienda[uds_pedidas] )
```

```dax
Uds Servidas = SUM ( fact_pedido_tienda[uds_servidas] )
```

**`Fill Rate`.** Unidades servidas sobre pedidas, de suma a suma.

```dax
Fill Rate = DIVIDE ( [Uds Servidas], [Uds Pedidas] )
```

**`Tasa Rotura`.** Complementario del fill rate.

```dax
Tasa Rotura = DIVIDE ( [Uds Pedidas] - [Uds Servidas], [Uds Pedidas] )
```

**`Venta Perdida`.** Margen de las unidades no servidas. En semanas de rebajas, el margen usa el pvp con el descuento elegido.

```dax
Venta Perdida =
VAR Descuento = [Descuento Seleccionado]
RETURN
    SUMX (
        fact_pedido_tienda,
        VAR Pvp = RELATED ( dim_producto[pvp] )
        VAR Coste = RELATED ( dim_producto[coste_unitario] )
        VAR Margen =
            IF (
                RELATED ( Calendario[EventoAlmacen] ) IN { "rebajas_invierno", "rebajas_verano" },
                Pvp * ( 1 - Descuento ) - Coste,
                Pvp - Coste
            )
        RETURN
            ( fact_pedido_tienda[uds_pedidas] - fact_pedido_tienda[uds_servidas] ) * Margen
    )
```

**`Retraso Medio Dias`.** Días entre fecha prevista y recepción, solo en pedidos recibidos.

```dax
Retraso Medio Dias =
AVERAGEX (
    FILTER ( fact_compra, NOT ISBLANK ( fact_compra[fecha_recepcion] ) ),
    ( fact_compra[fecha_recepcion] - fact_compra[fecha_prevista] ) * 1
)
```

**`% Uds Recibidas`.** Unidades recibidas sobre pedidas, solo en pedidos recibidos.

```dax
% Uds Recibidas =
CALCULATE (
    DIVIDE ( SUM ( fact_compra[uds_recibidas] ), SUM ( fact_compra[uds_pedidas] ) ),
    NOT ISBLANK ( fact_compra[fecha_recepcion] )
)
```

**`Lineas Pendientes`.** Líneas de compra sin recibir al cierre.

```dax
Lineas Pendientes =
CALCULATE ( COUNTROWS ( fact_compra ), ISBLANK ( fact_compra[fecha_recepcion] ) ) + 0
```

#### Página 2: inmovilizado (6)

El stock es una foto de cierre: no se suma entre semanas.

**`Valor Stock`.** Valor a coste en la última semana del contexto.

```dax
Valor Stock =
VAR Ultima = MAX ( fact_stock_semanal[semana] )
RETURN
    CALCULATE (
        SUMX (
            fact_stock_semanal,
            fact_stock_semanal[stock_final_uds] * RELATED ( dim_producto[coste_unitario] )
        ),
        fact_stock_semanal[semana] = Ultima
    )
```

**`Valor Stock Medio`.** Media de los valores semanales, sin la foto inicial.

```dax
Valor Stock Medio =
AVERAGEX (
    CALCULATETABLE ( VALUES ( fact_stock_semanal[semana] ), Calendario[IndiceSemana] >= 1 ),
    CALCULATE (
        SUMX (
            fact_stock_semanal,
            fact_stock_semanal[stock_final_uds] * RELATED ( dim_producto[coste_unitario] )
        )
    )
)
```

**`Valor Consumido`.** Unidades servidas por coste.

```dax
Valor Consumido =
SUMX (
    fact_pedido_tienda,
    fact_pedido_tienda[uds_servidas] * RELATED ( dim_producto[coste_unitario] )
)
```

**`Rotacion Anual`.**

```dax
Rotacion Anual = DIVIDE ( [Valor Consumido], [Valor Stock Medio] )
```

**`Valor Inmovilizado`.** Valor del stock de las referencias sin ninguna unidad servida en las 12 semanas que terminan en la semana analizada. Antes de la semana 12 queda en blanco.

```dax
Valor Inmovilizado =
VAR Ultima = MAX ( fact_stock_semanal[semana] )
VAR Indice = LOOKUPVALUE ( Calendario[IndiceSemana], Calendario[Fecha], Ultima )
RETURN
    IF (
        Indice >= 12,
        SUMX (
            VALUES ( dim_producto[id_sku] ),
            VAR Servidas12 =
                CALCULATE (
                    [Uds Servidas],
                    REMOVEFILTERS ( Calendario ),
                    Calendario[IndiceSemana] > Indice - 12
                        && Calendario[IndiceSemana] <= Indice
                )
            RETURN
                IF (
                    Servidas12 = 0,
                    CALCULATE (
                        [Valor Stock],
                        REMOVEFILTERS ( Calendario ),
                        fact_stock_semanal[semana] = Ultima
                    )
                )
        )
    )
```

**`% Inmovilizado`.**

```dax
% Inmovilizado = DIVIDE ( [Valor Inmovilizado], [Valor Stock] )
```

#### Página 3: política de reposición (4)

**`SKU`.**

```dax
SKU = COUNTROWS ( dim_producto )
```

**`Valor Stock Seguridad`.** Del año completo, sin ponderar por ventana.

```dax
Valor Stock Seguridad =
SUMX ( dim_producto, dim_producto[StockSeguridad] * dim_producto[coste_unitario] )
```

**`Valor Stock Objetivo`.** Valor del stock medio con la política propuesta.

```dax
Valor Stock Objetivo =
SUMX ( dim_producto, dim_producto[StockObjetivoMedio] * dim_producto[coste_unitario] )
```

**`Ahorro Anual`.** (Valor del stock medio actual - valor del stock objetivo) × coste de posesión.

```dax
Ahorro Anual =
VAR ValorActual = CALCULATE ( [Valor Stock Medio], REMOVEFILTERS ( Calendario ) )
RETURN
    -- Capital que dejaría de estar inmovilizado por el coste anual de mantenerlo
    -- (20% por defecto: hipótesis ajustable con el parámetro, no un dato)
    ( ValorActual - [Valor Stock Objetivo] ) * [Coste Posesion Seleccionado]
```

#### Página 4: recomendación de pedido (19)

Se calcula con el estado real de la semana de corte (la elegida en la segmentación; por defecto, la última). El pedido se lanza el lunes siguiente y llega tras el plazo del proveedor.

- **Mínimo** = demanda prevista durante el plazo + stock de seguridad. **Máximo** = mínimo + demanda prevista de las 4 semanas siguientes a la llegada.
- Si el stock más lo que viene en camino está en el mínimo o por debajo, se pide hasta el máximo.
- Las medidas por SKU usan `SELECTEDVALUE`: solo tienen sentido con un SKU en el contexto.

**Estado de la semana de corte**

**`Semana Corte`.**

```dax
Semana Corte = MAX ( Calendario[SemanaLunes] )
```

**`Stock Corte`.** Stock de cierre de la semana de corte.

```dax
Stock Corte =
VAR Corte = [Semana Corte]
RETURN
    CALCULATE (
        SUM ( fact_stock_semanal[stock_final_uds] ),
        REMOVEFILTERS ( Calendario ),
        fact_stock_semanal[semana] = Corte
    )
```

**`En Camino`.** Unidades pedidas a proveedor y no recibidas al cierre de la semana de corte.

```dax
En Camino =
VAR FinSemana = [Semana Corte] + 6
RETURN
    SUMX (
        FILTER (
            fact_compra,
            fact_compra[fecha_pedido] <= FinSemana
                && ( ISBLANK ( fact_compra[fecha_recepcion] ) || fact_compra[fecha_recepcion] > FinSemana )
        ),
        fact_compra[uds_pedidas]
    )
```

**`Semanas Sin Salida`.** Semanas desde la última salida hasta el corte. Si no hay salida desde que empezó la temporada, se cuenta desde el inicio de temporada; restos y SKU sin ventas, desde el 23/12/2024.

```dax
Semanas Sin Salida =
VAR Corte = [Semana Corte]
VAR Ultima =
    CALCULATE (
        MAX ( fact_pedido_tienda[semana] ),
        REMOVEFILTERS ( Calendario ),
        fact_pedido_tienda[uds_servidas] > 0,
        fact_pedido_tienda[semana] <= Corte
    )
VAR Inicio = COALESCE ( SELECTEDVALUE ( dim_producto[InicioTemporada] ), DATE ( 2024, 12, 23 ) )
RETURN
    DATEDIFF ( MAX ( COALESCE ( Ultima, Inicio ), Inicio ), Corte, DAY ) / 7
```

**Previsión de demanda**

**`Semanas Ciclo`.** Semanas de venta que cubre el pedido: las 4 siguientes a la llegada, recortadas al fin de temporada.

```dax
Semanas Ciclo =
VAR L = SELECTEDVALUE ( dim_producto[PlazoSemanas], 0 )
VAR Desde = MAX ( [Semana Corte] + 7 * ( L + 1 ), COALESCE ( SELECTEDVALUE ( dim_producto[InicioTemporada] ), 0 ) )
VAR Hasta = MIN ( [Semana Corte] + 7 * ( L + 4 ), COALESCE ( SELECTEDVALUE ( dim_producto[FinTemporada] ), DATE ( 2099, 1, 1 ) ) )
RETURN
    MAX ( 0, INT ( ( Hasta - Desde ) / 7 ) + 1 )
```

**`Prevision Plazo`.** Demanda prevista desde el lunes siguiente al corte hasta la llegada del pedido: las semanas de la ventana más lo que añade cada pico (multiplicador menos 1). Los básicos ignoran las rebajas.

```dax
Prevision Plazo =
VAR D = SELECTEDVALUE ( dim_producto[DemandaMedia], 0 )
VAR L = SELECTEDVALUE ( dim_producto[PlazoSemanas], 0 )
VAR EsBasico = SELECTEDVALUE ( dim_producto[tipo] ) = "basico"
VAR Desde = MAX ( [Semana Corte] + 7, COALESCE ( SELECTEDVALUE ( dim_producto[InicioTemporada] ), 0 ) )
VAR Hasta = MIN ( [Semana Corte] + 7 * L, COALESCE ( SELECTEDVALUE ( dim_producto[FinTemporada] ), DATE ( 2099, 1, 1 ) ) )
VAR Semanas = MAX ( 0, INT ( ( Hasta - Desde ) / 7 ) + 1 )
VAR Extra =
    SUMX (
        FILTER (
            ALL ( Calendario ),
            Calendario[Fecha] = Calendario[SemanaLunes]
                && Calendario[Fecha] >= Desde
                && Calendario[Fecha] <= Hasta
                && Calendario[TipoSemana] = "pico"
                && NOT ( EsBasico && LEFT ( Calendario[EventoAlmacen], 7 ) = "rebajas" )
        ),
        Calendario[MultEvento] - 1
    )
RETURN
    D * ( Semanas + Extra )
```

**`Prevision Ciclo`.** Igual, para las 4 semanas siguientes a la llegada.

```dax
Prevision Ciclo =
VAR D = SELECTEDVALUE ( dim_producto[DemandaMedia], 0 )
VAR L = SELECTEDVALUE ( dim_producto[PlazoSemanas], 0 )
VAR EsBasico = SELECTEDVALUE ( dim_producto[tipo] ) = "basico"
VAR Desde = MAX ( [Semana Corte] + 7 * ( L + 1 ), COALESCE ( SELECTEDVALUE ( dim_producto[InicioTemporada] ), 0 ) )
VAR Hasta = MIN ( [Semana Corte] + 7 * ( L + 4 ), COALESCE ( SELECTEDVALUE ( dim_producto[FinTemporada] ), DATE ( 2099, 1, 1 ) ) )
VAR Extra =
    SUMX (
        FILTER (
            ALL ( Calendario ),
            Calendario[Fecha] = Calendario[SemanaLunes]
                && Calendario[Fecha] >= Desde
                && Calendario[Fecha] <= Hasta
                && Calendario[TipoSemana] = "pico"
                && NOT ( EsBasico && LEFT ( Calendario[EventoAlmacen], 7 ) = "rebajas" )
        ),
        Calendario[MultEvento] - 1
    )
RETURN
    D * ( [Semanas Ciclo] + Extra )
```

**`Mult Ciclo`.** Cuánto sube la demanda media del ciclo por los eventos (1,00 sin eventos).

```dax
Mult Ciclo =
DIVIDE ( [Prevision Ciclo], SELECTEDVALUE ( dim_producto[DemandaMedia], 0 ) * [Semanas Ciclo], 1 )
```

**Política y acción**

**`Liquidar`.** 1 si hay stock y 12 o más semanas sin salidas.

```dax
Liquidar = IF ( [Stock Corte] > 0 && [Semanas Sin Salida] >= 12, 1, 0 )
```

**`Minimo`.** Previsión durante el plazo más stock de seguridad. En moda, el stock de seguridad vale la mitad y baja gradualmente en las últimas 4 semanas de temporada.

```dax
Minimo =
-- Decisión del proyecto: la moda lleva la mitad de colchón (no se repone tras su temporada)
VAR Factor = IF ( SELECTEDVALUE ( dim_producto[tipo] ) = "moda", 0.5, 1 )
RETURN
    -- Punto de pedido (ROP = D × L + ss, Chopra y Meindl) con la demanda prevista
    -- semana a semana, picos incluidos, en lugar de la media
    [Prevision Plazo]
        -- El colchón baja gradualmente en las últimas 4 semanas de temporada
        + SELECTEDVALUE ( dim_producto[StockSeguridad], 0 ) * Factor * MIN ( 1, [Semanas Ciclo] / 4 )
```

**`Maximo`.**

```dax
Maximo =
-- Sistema de mínimo y máximo (Silver, Pyke y Thomas, 2017):
-- el máximo añade al mínimo la demanda prevista de las 4 semanas siguientes a la llegada
[Minimo] + [Prevision Ciclo]
```

**`Uds a Pedir`.** Unidades hasta el máximo si el stock más lo que viene en camino está en el mínimo o por debajo. Es 0 si es un resto, no tiene demanda, el pedido se lanzaría más de una semana antes de que empiece su temporada, quedan menos de 2 semanas de ciclo o la acción es liquidar.

```dax
Uds a Pedir =
VAR Pos = [Stock Corte] + [En Camino]
VAR Inicio = COALESCE ( SELECTEDVALUE ( dim_producto[InicioTemporada] ), DATE ( 2000, 1, 1 ) )
VAR Pedir =
    SELECTEDVALUE ( dim_producto[Reponible], FALSE () )
        && SELECTEDVALUE ( dim_producto[DemandaMedia], 0 ) > 0
        && [Semana Corte] + 7 >= Inicio - 7
        && [Semanas Ciclo] >= 2
        && [Liquidar] = 0
        && Pos <= [Minimo]
RETURN
    -- Regla del mínimo y máximo: si stock + en camino está en el mínimo o por debajo,
    -- se pide hasta el máximo. Lo que ya viene en camino no se vuelve a pedir
    IF ( Pedir, MAX ( 0, ROUND ( [Maximo] - Pos, 0 ) ), 0 )
```

**`Accion`.** Una por SKU, por orden de prioridad: Liquidar, Pedir, Sin demanda, Sin acción.

```dax
Accion =
SWITCH (
    TRUE (),
    [Liquidar] = 1, "Liquidar",
    [Uds a Pedir] > 0, "Pedir",
    SELECTEDVALUE ( dim_producto[DemandaMedia], 0 ) = 0, "Sin demanda",
    "Sin acción"
)
```

**Pedido mínimo del proveedor**

El mínimo es por modelo (un pedido de compra es un modelo con todas sus tallas). Solo avisa: no bloquea ni completa el pedido.

**`Uds Pedir Modelo`.** Suma de las unidades a pedir de todas las tallas del modelo.

```dax
Uds Pedir Modelo =
VAR Modelo = SELECTEDVALUE ( dim_producto[id_modelo] )
RETURN
    CALCULATE (
        SUMX ( VALUES ( dim_producto[id_sku] ), [Uds a Pedir] ),
        ALL ( dim_producto ),
        dim_producto[id_modelo] = Modelo
    )
```

**`Faltan Uds`.** Unidades que faltan para llegar al mínimo del proveedor, si el modelo tiene algo que pedir.

```dax
Faltan Uds =
VAR Total = [Uds Pedir Modelo]
VAR MinProveedor = MAXX ( dim_producto, RELATED ( dim_proveedor[pedido_minimo_uds] ) )
RETURN
    IF ( Total > 0, MAX ( 0, MinProveedor - Total ) )
```

**Tarjetas**

**`SKU a Pedir`.**

```dax
SKU a Pedir = COUNTROWS ( FILTER ( VALUES ( dim_producto[id_sku] ), [Uds a Pedir] > 0 ) )
```

**`Valor a Pedir`.** A coste.

```dax
Valor a Pedir = SUMX ( dim_producto, [Uds a Pedir] * dim_producto[coste_unitario] )
```

**`Valor a Liquidar`.** Stock a coste de los SKU con acción Liquidar. Cuenta la antigüedad desde el inicio de temporada, a diferencia de `Valor Inmovilizado`.

```dax
Valor a Liquidar =
SUMX ( dim_producto, [Liquidar] * [Stock Corte] * dim_producto[coste_unitario] )
```

**`Modelos Bajo Minimo`.** Modelos con pedido que no llegan al mínimo del proveedor.

```dax
Modelos Bajo Minimo = COUNTROWS ( FILTER ( VALUES ( dim_producto[id_modelo] ), [Faltan Uds] > 0 ) )
```

## 5. Limitaciones del modelo

- **Datos sintéticos.** El dataset se generó con patrones de comportamiento definidos de antemano. Las cifras del dashboard demuestran que el método detecta y cuantifica esos patrones, no que existan en un negocio real, y no son extrapolables a uno.
- **Alcance reducido.** Un solo año, 5 proveedores y 6 tiendas. Quedan fuera ubicaciones, picking, devoluciones, ecommerce y colores.
- **Un solo año de historia.** No hay base para estimar un índice estacional, así que las semanas de evento se excluyen del cálculo de demanda y los picos se tratan aparte con multiplicadores fijos.
- **Demanda y clasificación con el año completo.** La demanda media, la varianza y la clase ABC/XYZ usan todos los datos, también los posteriores a la semana de corte de la página 4.
- **El ahorro de la página 3 es una aproximación analítica.** Compara el stock medio observado con un stock objetivo teórico; no simula la nueva política. Depende del coste de posesión elegido y del plazo adoptado para P04.
- **La recomendación de la página 4 es una decisión de un momento,** no un año simulado: no tiene cifra anual de ahorro ni de nivel de servicio.
- **Calendario de eventos hasta el 28/12/2025.** La previsión no ve picos posteriores (el corte del 22/12 prevé sin eventos) y el fin de temporada de OI25 es una estimación.
- **Constantes fijas en el DAX.** Multiplicadores de evento, fechas de temporada, factor 0,5 del stock de seguridad de la moda y niveles de servicio por clase están escritos en las fórmulas; no son parámetros.
- **Pedido mínimo del proveedor.** Se aplica por modelo y solo avisa: no completa el pedido hasta el mínimo.
- **Retraso medio subestimado.** `Retraso Medio Dias` solo cuenta pedidos recibidos, y los más retrasados siguen pendientes al cierre; hay que leerlo junto a `Lineas Pendientes`.

## 6. Referencias

Las fórmulas de la política de reposición siguen la teoría estándar de gestión de inventarios:

- **Chopra, S. y Meindl, P.** *Supply Chain Management: Strategy, Planning, and Operation*. Pearson. Capítulo «Managing Uncertainty in a Supply Chain: Safety Inventory» (su número cambia según la edición). Fórmula del stock de seguridad con demanda y plazo inciertos y relación entre nivel de servicio y z (`StockSeguridad`).
- **Silver, E. A., Pyke, D. F. y Thomas, D. J. (2017).** *Inventory and Production Management in Supply Chains* (4.ª ed.). CRC Press. Clasificación ABC, punto de pedido, sistema de mínimo y máximo y stock medio como stock de seguridad más medio pedido (`PuntoPedido`, `StockObjetivoMedio`, `Minimo`, `Maximo`).
- **Scholz-Reiter, B., Heger, J., Meinecke, C. y Bergmann, J. (2012).** «Integration of demand forecasts in ABC-XYZ analysis: practical investigation at an industrial company». *International Journal of Productivity and Performance Management*, 61(4), 445-451. https://doi.org/10.1108/17410401211212689. Clasificación ABC/XYZ combinada (`ClaseABC`, `ClaseXYZ`).

No tienen fuente externa, porque son hipótesis o decisiones del proyecto: los umbrales de la clase XYZ (0,5 y 1, una convención habitual), los niveles de servicio por clase, el pedido de 4 semanas, el coste de posesión del 20%, la ponderación por semanas de venta, los multiplicadores de evento y el plazo observado de P04.
