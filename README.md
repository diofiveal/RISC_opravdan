# RISC оправдан

# SCR1 Cache Improvements

## Краткое описание
Основная цель работы - улучшение подсистемы памяти открытого процессора SCR1
В данной версии SCR1 подсистема памяти была расширена кэш-памятью первого уровня для инструкций и данных, а также небольшим Victim Cache для instruction path.

Основные добавленные блоки:

- L1 Instruction Cache;
- Instruction Victim Cache;
- L1 Data Cache;
- cache bypass для диапазона `0xFF00_0000 - 0xFFFF_FFFF`;
- performance counters для анализа работы кэшей в simulation;
- BRAM-ориентированная реализация массивов DATA/TAG.

---

## Архитектура

<img width="1200" height="1400" alt="Текущая Микроархитектура" src="https://github.com/user-attachments/assets/c237ef76-a11c-4c58-a691-de50e0e0e581" />

# L1 Instruction Cache

## Основные характеристики

- Тип: direct-mapped L1 instruction cache;
- Размер по умолчанию: **2 KiB**;
- Размер cache line: **8 байт**;
- 2 слова по 32 бита в одной cache line;
- Blocking cache;
- Последовательный refill строки по словам;
- DATA и TAG массивы реализованы как синхронная память;
- DATA/TAG ориентированы на использование FPGA Block RAM;
- VALID bits хранятся отдельно в регистрах;
- Адреса `0xFF00_0000 - 0xFFFF_FFFF` обходят L1 I-cache.

## Состав блока

### `icache.sv`

Хранилище L1 Instruction Cache.

Основные функции:

- хранение DATA;
- хранение TAG;
- хранение VALID bits;
- синхронный lookup;
- запись данных при refill;
- commit TAG после заполнения строки;
- invalidation строки.

### `icache_controller.sv`

Управляющий модуль L1 Instruction Cache.

Основные функции:

- FSM обработки запросов;
- определение hit/miss;
- управление refill;
- инвалидация вытесняемой строки L1 перед refill новой строки;
- формирование запросов во внешнюю память;
- обработка uncached/bypass обращений;
- Victim Cache lookup;
- сохранение вытесняемой L1 строки в Victim Cache;
- Round-Robin выбор Victim entry.

### `scr1_icache_top.sv`

Верхний модуль instruction cache subsystem.

Объединяет:

- `icache.sv`;
- `icache_controller.sv`;
- `victim_icache.sv`.

Также содержит simulation-only performance counters для I-cache.

---

# Instruction Victim Cache

## Основные характеристики

- Количество entries по умолчанию: **4**;
- Fully-associative организация;
- Размер одной строки: **8 байт**;
- Хранится полная вытесненная строка L1 I-cache;
- Victim TAG формируется как комбинация L1 TAG и L1 INDEX;
- Поиск выполняется по всем Victim entries;
- Replacement policy: Round-Robin;
- При Victim hit данные возвращаются непосредственно из Victim Cache;
- Promotion/swap Victim line обратно в L1 на текущем этапе не реализован.

## Состав блока

### `victim_icache.sv`

Хранилище и lookup-логика Victim Cache.

Основные функции:

- хранение DATA для каждой Victim entry;
- хранение полного Victim TAG;
- хранение VALID bits;
- fully-associative lookup;
- выдача выбранного слова;
- выдача полной cache line;
- запись вытесняемой L1 строки;
- invalidation Victim entry.

### Интеграция с `icache_controller.sv`

`icache_controller.sv` отвечает за:

- запуск Victim lookup после L1 miss;
- выбор Victim entry для записи;
- чтение вытесняемой L1 строки;
- запись строки в Victim Cache;
- продолжение refill при L1 + Victim miss.

### Интеграция с `scr1_icache_top.sv`

`scr1_icache_top.sv` соединяет Victim Cache с L1 I-cache и его controller.

---

# L1 Data Cache

## Основные характеристики

- Тип: direct-mapped L1 data cache;
- Размер по умолчанию: **2 KiB**;
- Размер cache line: **8 байт**;
- 2 слова по 32 бита в одной cache line;
- Blocking cache;
- Поддержка BYTE / HALFWORD / WORD load и store;
- Write-through policy;
- Write-allocate при store miss;
- Последовательный refill строки по словам;
- DATA и TAG массивы реализованы как синхронная память;
- DATA/TAG ориентированы на FPGA Block RAM;
- VALID bits хранятся отдельно в регистрах;
- Адреса `0xFF00_0000 - 0xFFFF_FFFF` обходят L1 D-cache.

## Состав блока

### `dcache.sv`

Хранилище L1 Data Cache.

Основные функции:

- хранение DATA;
- хранение TAG;
- хранение VALID bits;
- синхронный lookup;
- запись данных при refill;
- обновление cached word после store;
- commit TAG после refill;
- инвалидация вытесняемой строки L1 перед refill новой строки.

Для DATA RAM refill и store используют один физический write port через внутренний mux.

### `dcache_controller.sv`

Управляющий модуль L1 Data Cache.

Основные функции:

- FSM обработки load/store запросов;
- проверка типа и выравнивания доступа;
- определение hit/miss;
- управление refill;
- обработка BYTE / HALFWORD / WORD;
- write-through store;
- write-allocate при store miss;
- управление cache update после store;
- формирование запросов во внешнюю память;
- обработка uncached/bypass обращений.

### `scr1_dcache_top.sv`

Верхний модуль data cache subsystem.

Объединяет:

- `dcache.sv`;
- `dcache_controller.sv`.

Также содержит simulation-only performance counters для D-cache.

---

# Performance counters

В simulation для анализа работы L1 cache добавлены счётчики.

## I-cache

- accesses;
- hits;
- misses;
- refill words;
- stall cycles.

## D-cache

- load accesses;
- store accesses;
- hits;
- misses;
- load misses;
- store misses;
- refill words;
- stall cycles.

Счётчики доступны при включённом `SCR1_TRGT_SIMULATION`.

---

# Изменённые top-level модули

Для подключения новых блоков изменены:

- `scr1_top_axi.sv`;
- `scr1_top_ahb.sv`.

Внешние instruction/data memory requests теперь могут проходить через L1 cache перед передачей в AHB/AXI memory interface.

TCM и memory-mapped timer остаются отдельными блоками существующей архитектуры SCR1.

---

# Добавленные RTL-файлы

| Файл | Назначение |
|---|---|
| `icache.sv` | Хранилище DATA/TAG/VALID L1 I-cache |
| `icache_controller.sv` | FSM и управление L1 I-cache / Victim / refill |
| `scr1_icache_top.sv` | Интеграция I-cache subsystem |
| `victim_icache.sv` | Fully-associative Victim Cache |
| `dcache.sv` | Хранилище DATA/TAG/VALID L1 D-cache |
| `dcache_controller.sv` | FSM и управление L1 D-cache |
| `scr1_dcache_top.sv` | Интеграция D-cache subsystem |

---

# Текущая конфигурация

|     Блок       |  Размер   | Cache line    | Организация       |
|     ----       |   ---     |     ---       |     ---           |
| L1 I-cache     | 2 KiB     |     8 B       | Direct-mapped     |
| Victim I-cache | 4 entries |     8 B       | Fully associative |
| L1 D-cache     | 2 KiB     |     8 B       | Direct-mapped     |

# Сравнение SCR1 без кэша и SCR1 c текущей модификацией.
<img width="1192" height="605" alt="Сравнение результатов" src="https://github.com/user-attachments/assets/72063a4a-7029-41f2-86c8-cc7110a9a692" />

Ускорение - метрика, означающая во сколько раз SCR1 с текущей модификацией показывает себя быстрее на тесте относительно SCR1 без улучшения.
