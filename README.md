# 📦 Optimización de inventario

Análisis y **Dashboard de salud de inventario** para el almacén central de una marca de calzado y textil: dónde se rompe el stock, cuánto capital está parado y qué política de reposición aplicar.

**Pregunta de negocio:** ¿cómo reducir a la vez las roturas de stock y el capital inmovilizado, y con qué política de reposición?

## 📊 Resultados en cifras

| Página                 | Pregunta                                       | Respuesta                                                                                                                                                                                                                         | Consulta                                                                |
| ---------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| 🔴 **1. Rotura**       | ¿Dónde se rompe el stock?                      | El 9,5% de las unidades que piden las tiendas no se sirve. Se rompe en las tallas centrales (11 puntos menos de servicio), en los picos de demanda (14 puntos menos) y en el proveedor P04, que rompe 2,6 veces más que el resto. | [`p1_roturas.sql`](sql/p1_roturas.sql)                                  |
| 🧊 **2. Inmovilizado** | ¿Cuánto capital está parado?                   | 221.148 €, el 36% del valor del stock, lleva 12 semanas o más sin salir. Todo es moda: restos de temporadas anteriores y producto de primavera-verano 2025 que no se vendió.                                                      | [`p2_inmovilizado.sql`](sql/p2_inmovilizado.sql)                        |
| 🔄 **3. Reposición**   | ¿Qué política corresponde a cada referencia?   | Fijar stock de seguridad y punto de pedido por segmento bajaría el stock medio un 57% y ahorraría 70.248 € al año en costes de mantenerlo.                                                                                        | [`p3_reposicion.sql`](sql/p3_reposicion.sql)                            |
| 🛒 **4. Pedido**       | ¿Qué hay que pedir y qué liquidar esta semana? | A 22/12/2025, pedir 122 referencias (241.916 €) y liquidar 225 (221.148 €).                                                                                                                                                       | [Medidas DAX](docs/modelo_y_dax.md#página-4-recomendación-de-pedido-19) |

## 📚 Documentación

| Documento | Qué contiene |
|---|---|
| 🔎 [**Hallazgos por página**](docs/hallazgos.md) | Las cifras de cada página del dashboard con su lectura, cómo se calcula la política de reposición paso a paso y las decisiones de método. |
| 🧮 [**Modelo y DAX**](docs/modelo_y_dax.md) | Origen de los datos, modelo y relaciones, todas las columnas y medidas DAX comentadas, limitaciones y referencias bibliográficas de las fórmulas. |

## 🖥️ El dashboard

Cuatro páginas, una por pregunta. Cada captura enlaza con sus hallazgos.

| | |
|---|---|
| [![Página 1: Rotura](docs/img/dashboard_p1.png)](docs/hallazgos.md#página-1-dónde-se-rompe-el-stock) | [![Página 2: Inmovilizado](docs/img/dashboard_p2.png)](docs/hallazgos.md#página-2-cuánto-capital-está-parado) |
| [![Página 3: Reposición](docs/img/dashboard_p3.png)](docs/hallazgos.md#página-3-qué-política-de-reposición-corresponde) | [![Página 4: Pedido](docs/img/dashboard_p4.png)](docs/hallazgos.md#página-4-qué-hay-que-pedir-y-qué-liquidar) |

## 💡 Qué recomienda

- **Política por segmento.** Cada referencia recibe un stock de seguridad y un punto de pedido según su clasificación ABC/XYZ: por valor vendido (A, B, C) y por previsibilidad de la demanda (X estable, Y variable, Z errática).
- **Pedido con mínimo y máximo.** Con el estado real de la semana, se pide hasta el máximo cuando el stock más lo que viene en camino está en el mínimo o por debajo. Las referencias con 12 semanas o más sin salida se liquidan, no se reponen.
- **Plazos reales.** P04 declara 35 días de plazo, pero tarda de media 51: hay que planificarlo con 8 semanas, no con 5.
- **De dónde sale el ahorro de 70.248 €.** El stock medio actual es de 621.399 € y, con la política propuesta, sería de 270.158 €: 351.241 € menos de capital parado. Mantener stock cuesta cada año un 20% de su valor (capital, almacenaje, obsolescencia), y ese 20% sobre la diferencia da el ahorro anual.

## 🛠️ Cómo está hecho

| Pieza | Qué aporta |
|---|---|
| 📄 **CSV** | Modelo en estrella con 5 dimensiones y 3 tablas de hechos: pedidos de tienda, stock semanal y compras a proveedor. |
| 🗄️ **SQLite** | Tres consultas de análisis, una por pregunta: [`p1_roturas`](sql/p1_roturas.sql), [`p2_inmovilizado`](sql/p2_inmovilizado.sql) y [`p3_reposicion`](sql/p3_reposicion.sql). La página 4 no tiene consulta SQL: se calcula con medidas DAX. |
| 📊 **Power BI y DAX** | Modelo con 20 columnas calculadas y 39 medidas, y las 4 páginas del dashboard. Cada tabla, relación y fórmula está documentada en [`modelo_y_dax.md`](docs/modelo_y_dax.md). |

## 📁 Estructura del repositorio

```text
proyecto-optimizacion-inventario/
├── README.md
├── LICENSE
├── data/
│   ├── almacen.db            base SQLite (tablas y vistas de apoyo)
│   └── csv/                  8 tablas en CSV
├── sql/
│   ├── p1_roturas.sql
│   ├── p2_inmovilizado.sql
│   └── p3_reposicion.sql
├── powerbi/
│   └── dashboard.pbix
└── docs/
    ├── hallazgos.md          hallazgos por página
    ├── modelo_y_dax.md       modelo de datos y medidas DAX
    └── img/                  capturas del dashboard
        ├── dashboard_p1.png  página 1: rotura
        ├── dashboard_p2.png  página 2: inmovilizado
        ├── dashboard_p3.png  página 3: reposición
        └── dashboard_p4.png  página 4: pedido
```

## ▶️ Cómo abrirlo y reproducirlo

1. **Dashboard.** Abre `powerbi/dashboard.pbix` con Power BI Desktop. En la página 4, elige la semana de corte con el selector; sin selección usa la última (22/12/2025).
2. **Actualizar los datos.** El informe trae los datos ya cargados. Para refrescarlos, en *Transformar datos > Configuración del origen de datos* cambia la ruta a tu carpeta `data/csv/`.
3. **Consultas SQL.** Abre `data/almacen.db` con cualquier cliente SQLite (por ejemplo, DB Browser for SQLite) y ejecuta los archivos de [`sql/`](sql/). La consulta `p3_reposicion` usa las vistas que ya incluye la base.

## 📖 Glosario

| Término                           | Significado                                                                                                                                                                   |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Referencia (SKU)**              | Cada combinación de modelo y talla.                                                                                                                                           |
| **Rotura de stock**               | Una tienda pide más unidades de las que el almacén puede servir.                                                                                                              |
| **Fill rate (nivel de servicio)** | Porcentaje de unidades pedidas que se sirven. La tasa de rotura es lo que falta para el 100%.                                                                                 |
| **Curva de tallas**               | Reparto de la demanda entre tallas: las centrales se piden más que las extremas.                                                                                              |
| **Stock inmovilizado**            | Valor del stock de las referencias sin ninguna salida en las últimas 12 semanas.                                                                                              |
| **Rotación**                      | Veces al año que se renueva el stock: lo servido a coste entre el stock medio.                                                                                                |
| **Plazo de entrega**              | Días entre que se pide a un proveedor y se recibe la mercancía.                                                                                                               |
| **Stock de seguridad**            | Colchón que absorbe la variación de la demanda y los retrasos del proveedor.                                                                                                  |
| **Punto de pedido**               | Nivel de stock en el que hay que pedir: demanda durante el plazo más stock de seguridad.                                                                                      |
| **Mínimo y máximo**               | Límites del sistema de reposición: al llegar al mínimo se pide hasta el máximo.                                                                                               |
| **Clasificación ABC/XYZ**         | ABC ordena por valor vendido (A es el 80% del valor, B el siguiente 15% y C el 5% restante). XYZ ordena por previsibilidad de la demanda (X estable, Y variable, Z errática). |
| **Coste de posesión**             | Coste anual de mantener stock, como porcentaje de su valor a coste. Aquí, el 20%.                                                                                             |

## ⚠️ Limitaciones

Es un **dataset sintético con varias limitaciones**, que se detallan en [docs/modelo_y_dax.md](docs/modelo_y_dax.md#5-limitaciones-del-modelo).

## 📄 Licencia

Publicado bajo licencia [MIT](LICENSE).
